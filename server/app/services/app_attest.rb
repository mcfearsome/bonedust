# frozen_string_literal: true

require "openssl"
require "securerandom"

# App Attest (§6): proves a request came from a genuine, unmodified build of this app on
# real Apple hardware.
#
# Two phases, both implemented here:
#
#   1. **Registration.** The client attests a freshly generated Secure Enclave key. The
#      server checks Apple's certificate chain, that the challenge it issued appears in
#      the certificate's App Attest extension, that the key id really is the SHA-256 of
#      the public key, and that the relying-party hash matches this app. It then stores
#      the public key.
#   2. **Assertion.** Every later request is signed by that key over a hash of its own
#      body plus a fresh challenge. The server verifies the signature and that the
#      hardware counter went up, which is what stops a captured request being replayed.
#
# Honest limit: the registration path has never been run against a real device, because
# that needs a provisioned build and Apple's root certificate, which is why the root is a
# configured file rather than something baked in. The assertion path — the one that runs
# on every payment — is tested with synthetic keys in `spec/app_attest_spec.rb`.
class AppAttest
  class Failure < StandardError; end

  CHALLENGE_TTL = 2.minutes
  # Apple's App Attest Root CA, PEM. Absent in development.
  ROOT_PATH = Rails.root.join("config/apple_app_attest_root.pem")
  # The OID carrying the challenge nonce in the leaf certificate.
  NONCE_OID = "1.2.840.113635.100.8.2"

  # Apple stamps the authenticator with "appattestdevelop" for a development attestation
  # and "appattest" plus null padding for a production one.
  #
  # Checked because accepting the development aaguid in production would let anybody with a
  # dev-provisioned build attest a key — a far easier bar than shipping through App Review,
  # and the obvious way in once the relying-party check is closed.
  DEVELOPMENT_AAGUID = "appattestdevelop"
  PRODUCTION_AAGUID = "appattest#{"\x00" * 7}".b

  class << self
    # Permissive mode exists so the service can be run locally without a provisioned
    # device. It must never be on in production, which `required?` enforces rather than
    # trusting a deploy checklist.
    def permissive?
      !Rails.env.production? && ENV["ATTEST_MODE"] == "permissive"
    end

    def required?
      Rails.env.production? || !permissive?
    end

    # A one-shot nonce. Stored so an assertion cannot be replayed even within its TTL.
    def issue_challenge(install_id)
      AttestChallenge.where(expires_at: ...Time.current).delete_all
      AttestChallenge.create!(
        install_id: install_id,
        nonce: SecureRandom.urlsafe_base64(32),
        expires_at: Time.current + CHALLENGE_TTL
      )
    end

    def consume_challenge!(install_id, nonce)
      challenge = AttestChallenge.find_by(nonce: nonce, install_id: install_id)
      raise Failure, "unknown challenge" if challenge.nil?
      raise Failure, "challenge already used" if challenge.consumed_at.present?
      raise Failure, "challenge expired" if challenge.expires_at < Time.current

      challenge.update!(consumed_at: Time.current)
      challenge
    end

    # Phase 1. Returns the public key to store against the digger.
    def register!(digger:, key_id:, attestation:, challenge_nonce:, request_body: "")
      return permissive_key(digger, key_id) if permissive?

      consume_challenge!(digger.install_id, challenge_nonce)
      object = CborReader.decode(Base64.decode64(attestation))
      raise Failure, "unexpected format" unless object["fmt"] == "apple-appattest"

      statement = object.fetch("attStmt") { raise Failure, "no attStmt" }
      chain = Array(statement["x5c"]).map { |der| OpenSSL::X509::Certificate.new(der) }
      raise Failure, "empty certificate chain" if chain.empty?

      verify_chain!(chain)
      auth_data = parse_auth_data(object.fetch("authData") { raise Failure, "no authData" })

      client_data_hash = OpenSSL::Digest::SHA256.digest(request_body.to_s + challenge_nonce)
      expected_nonce = OpenSSL::Digest::SHA256.digest(auth_data[:raw] + client_data_hash)
      verify_nonce_extension!(chain.first, expected_nonce)

      public_key = chain.first.public_key
      verify_key_id!(key_id, public_key)
      verify_rp_id!(auth_data[:rp_id_hash])
      verify_aaguid!(auth_data[:raw], expected: true)

      digger.update!(
        attest_key_id: key_id,
        attest_public_key: public_key.to_der,
        attest_counter: auth_data[:counter]
      )
      public_key
    end

    # Phase 2. Runs on every payment.
    def verify_assertion!(digger:, assertion:, challenge_nonce:, request_body: "")
      return true if permissive?

      raise Failure, "device not registered" if digger.attest_public_key.blank?

      consume_challenge!(digger.install_id, challenge_nonce)
      object = CborReader.decode(Base64.decode64(assertion))
      signature = object.fetch("signature") { raise Failure, "no signature" }
      auth_data = parse_auth_data(object.fetch("authenticatorData") { raise Failure, "no authData" })

      client_data_hash = OpenSSL::Digest::SHA256.digest(request_body.to_s + challenge_nonce)
      digest = OpenSSL::Digest::SHA256.digest(auth_data[:raw] + client_data_hash)

      key = OpenSSL::PKey::EC.new(digger.attest_public_key)
      unless key.dsa_verify_asn1(digest, signature)
        raise Failure, "signature does not verify"
      end

      # The Secure Enclave counter only ever increases. A replayed request carries a
      # counter the server has already seen, which is the whole point of storing it.
      if auth_data[:counter] <= digger.attest_counter
        raise Failure, "counter did not advance"
      end

      verify_rp_id!(auth_data[:rp_id_hash])
      digger.update!(attest_counter: auth_data[:counter])
      true
    end

    private

    def permissive_key(digger, key_id)
      digger.update!(attest_key_id: key_id.presence || "permissive-#{digger.install_id}")
      nil
    end

    # authenticatorData: 32 bytes rpIdHash, 1 byte flags, 4 bytes big-endian counter.
    def parse_auth_data(bytes)
      raise Failure, "authData too short" if bytes.bytesize < 37

      {
        raw: bytes,
        rp_id_hash: bytes[0, 32],
        flags: bytes[32].unpack1("C"),
        counter: bytes[33, 4].unpack1("N")
      }
    end

    def verify_chain!(chain)
      root = load_root
      raise Failure, "no Apple root certificate configured" if root.nil?

      store = OpenSSL::X509::Store.new
      store.add_cert(root)
      context = OpenSSL::X509::StoreContext.new(store, chain.first, chain[1..] || [])
      raise Failure, "certificate chain does not verify" unless context.verify
    end

    def verify_nonce_extension!(leaf, expected_nonce)
      extension = leaf.extensions.find { |ext| ext.oid == NONCE_OID }
      raise Failure, "no App Attest nonce extension" if extension.nil?

      # The extension wraps the nonce in a SEQUENCE; comparing containment rather than
      # re-encoding the ASN.1 keeps this robust to Apple's exact wrapper.
      raise Failure, "nonce mismatch" unless extension.value_der.to_s.include?(expected_nonce)
    end

    def verify_key_id!(key_id, public_key)
      raw = public_key.public_key.to_bn.to_s(2)
      expected = Base64.strict_encode64(OpenSSL::Digest::SHA256.digest(raw))
      raise Failure, "key id does not match public key" unless secure_equal?(key_id.to_s, expected)
    end

    # Fails closed. An unset APP_ATTEST_APP_ID used to mean "skip this check", which was
    # an authentication bypass dressed as a development convenience.
    #
    # App Attest proves "this is *your* app on genuine Apple hardware". Without the
    # relying-party check it only proves "this is *some* app on genuine hardware" — which
    # anybody holding an App Attest entitlement can produce for an app they wrote, register
    # against this server, and then use to mint payments indefinitely. The signature would
    # verify and the counter would advance, because the key really is theirs.
    def verify_rp_id!(rp_id_hash)
      app_id = ENV["APP_ATTEST_APP_ID"]
      if app_id.blank?
        raise Failure, "APP_ATTEST_APP_ID is not configured" if required?

        return   # permissive development only, never when attestation is enforced
      end

      expected = OpenSSL::Digest::SHA256.digest(app_id)
      raise Failure, "relying party mismatch" unless secure_equal?(rp_id_hash, expected)
    end

    # `expected` says whether the caller requires attestedCredentialData to be present.
    #
    # An assertion legitimately has none, so it passes false. A registration must have it,
    # and passes true — otherwise truncated authenticator data would skip this check
    # silently, which is the same fail-open shape as the relying-party hole and worth
    # closing even though Apple's nonce extension already binds the real authData to the
    # certificate and makes truncation unusable in practice.
    def verify_aaguid!(bytes, expected: false)
      if bytes.bytesize < 53
        raise Failure, "attestation carries no credential data" if expected

        return
      end

      aaguid = bytes[37, 16].b
      case aaguid
      when PRODUCTION_AAGUID then nil
      when DEVELOPMENT_AAGUID.b
        raise Failure, "development attestation refused" if Rails.env.production?
      else
        raise Failure, "unrecognised authenticator"
      end
    end

    def load_root
      return @root if defined?(@root)

      @root = File.exist?(ROOT_PATH) ? OpenSSL::X509::Certificate.new(File.read(ROOT_PATH)) : nil
    end

    def secure_equal?(lhs, rhs)
      return false unless lhs.bytesize == rhs.bytesize

      OpenSSL.secure_compare(lhs, rhs)
    end
  end
end
