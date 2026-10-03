# frozen_string_literal: true

require "rails_helper"

# The assertion path, with real P-256 keys.
#
# This is the half of App Attest that runs on every payment, so it is tested properly
# rather than trusted. The registration half needs Apple's root certificate and a
# provisioned device, neither of which exists here; what it does is written out in
# app/services/app_attest.rb and flagged in DECISIONS.md as unverified.
RSpec.describe AppAttest do
  # A minimal CBOR encoder, for building the payloads Apple would send. Only the three
  # types an assertion contains.
  def cbor(value)
    case value
    when Integer then head(0, value)
    when String
      value.encoding == Encoding::BINARY ? head(2, value.bytesize) + value
                                         : head(3, value.bytesize) + value.b
    when Hash
      head(5, value.size) + value.map { |k, v| cbor(k) + cbor(v) }.join
    else raise ArgumentError, "unsupported #{value.class}"
    end
  end

  def head(major, length)
    base = major << 5
    case length
    when 0..23 then [base | length].pack("C")
    when 24..0xFF then [base | 24, length].pack("CC")
    when 0x100..0xFFFF then [base | 25, length].pack("Cn")
    else [base | 26, length].pack("CN")
    end
  end

  def auth_data(counter:, rp_id_hash: OpenSSL::Digest::SHA256.digest("team.app"))
    (rp_id_hash + [0x40].pack("C") + [counter].pack("N")).b
  end

  def assertion_for(key, body:, nonce:, counter:, rp_id_hash: nil)
    data = rp_id_hash ? auth_data(counter: counter, rp_id_hash: rp_id_hash)
                      : auth_data(counter: counter)
    client_data_hash = OpenSSL::Digest::SHA256.digest(body + nonce)
    digest = OpenSSL::Digest::SHA256.digest(data + client_data_hash)
    signature = key.dsa_sign_asn1(digest)
    Base64.strict_encode64(cbor({ "signature" => signature.b, "authenticatorData" => data }))
  end

  let(:key) { OpenSSL::PKey::EC.generate("prime256v1") }
  let(:digger) do
    Digger.for_install(SecureRandom.uuid).tap do |d|
      d.update!(attest_public_key: public_der(key), attest_counter: 0)
    end
  end
  let(:body) { '{"amount":90}' }

  def public_der(private_key)
    OpenSSL::PKey::EC.new(private_key.public_to_der).to_der
  end

  before do
    # Permissive mode is on for request specs; this spec is about the real path.
    allow(described_class).to receive(:permissive?).and_return(false)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("APP_ATTEST_APP_ID").and_return("team.app")
  end

  it "accepts a correctly signed assertion and advances the counter" do
    nonce = described_class.issue_challenge(digger.install_id).nonce
    assertion = assertion_for(key, body: body, nonce: nonce, counter: 1)
    expect(
      described_class.verify_assertion!(
        digger: digger, assertion: assertion, challenge_nonce: nonce, request_body: body
      )
    ).to be(true)
    expect(digger.reload.attest_counter).to eq(1)
  end

  it "refuses a signature from a different key" do
    nonce = described_class.issue_challenge(digger.install_id).nonce
    impostor = OpenSSL::PKey::EC.generate("prime256v1")
    assertion = assertion_for(impostor, body: body, nonce: nonce, counter: 1)
    expect {
      described_class.verify_assertion!(
        digger: digger, assertion: assertion, challenge_nonce: nonce, request_body: body
      )
    }.to raise_error(described_class::Failure, /signature/)
  end

  it "refuses an assertion signed over a different body" do
    # This is what stops a captured payment being resent with the amount changed.
    nonce = described_class.issue_challenge(digger.install_id).nonce
    assertion = assertion_for(key, body: body, nonce: nonce, counter: 1)
    expect {
      described_class.verify_assertion!(
        digger: digger, assertion: assertion, challenge_nonce: nonce,
        request_body: '{"amount":999999}'
      )
    }.to raise_error(described_class::Failure, /signature/)
  end

  it "refuses a replay, because the counter has to advance" do
    nonce = described_class.issue_challenge(digger.install_id).nonce
    assertion = assertion_for(key, body: body, nonce: nonce, counter: 5)
    described_class.verify_assertion!(
      digger: digger, assertion: assertion, challenge_nonce: nonce, request_body: body
    )

    replay_nonce = described_class.issue_challenge(digger.install_id).nonce
    replayed = assertion_for(key, body: body, nonce: replay_nonce, counter: 5)
    expect {
      described_class.verify_assertion!(
        digger: digger, assertion: replayed, challenge_nonce: replay_nonce, request_body: body
      )
    }.to raise_error(described_class::Failure, /counter/)
  end

  it "refuses a nonce that has already been spent" do
    nonce = described_class.issue_challenge(digger.install_id).nonce
    described_class.verify_assertion!(
      digger: digger,
      assertion: assertion_for(key, body: body, nonce: nonce, counter: 1),
      challenge_nonce: nonce, request_body: body
    )
    expect {
      described_class.verify_assertion!(
        digger: digger,
        assertion: assertion_for(key, body: body, nonce: nonce, counter: 2),
        challenge_nonce: nonce, request_body: body
      )
    }.to raise_error(described_class::Failure, /already used/)
  end

  it "refuses an expired nonce" do
    challenge = described_class.issue_challenge(digger.install_id)
    challenge.update!(expires_at: 1.minute.ago)
    expect {
      described_class.verify_assertion!(
        digger: digger,
        assertion: assertion_for(key, body: body, nonce: challenge.nonce, counter: 1),
        challenge_nonce: challenge.nonce, request_body: body
      )
    }.to raise_error(described_class::Failure, /expired/)
  end

  it "refuses another install's nonce" do
    other = described_class.issue_challenge(SecureRandom.uuid)
    expect {
      described_class.verify_assertion!(
        digger: digger,
        assertion: assertion_for(key, body: body, nonce: other.nonce, counter: 1),
        challenge_nonce: other.nonce, request_body: body
      )
    }.to raise_error(described_class::Failure, /unknown challenge/)
  end

  it "refuses an assertion for a different app" do
    nonce = described_class.issue_challenge(digger.install_id).nonce
    wrong = assertion_for(
      key, body: body, nonce: nonce, counter: 1,
      rp_id_hash: OpenSSL::Digest::SHA256.digest("someone.else")
    )
    expect {
      described_class.verify_assertion!(
        digger: digger, assertion: wrong, challenge_nonce: nonce, request_body: body
      )
    }.to raise_error(described_class::Failure, /relying party/)
  end

  it "refuses a device that never registered" do
    stranger = Digger.for_install(SecureRandom.uuid)
    nonce = described_class.issue_challenge(stranger.install_id).nonce
    expect {
      described_class.verify_assertion!(
        digger: stranger,
        assertion: assertion_for(key, body: body, nonce: nonce, counter: 1),
        challenge_nonce: nonce, request_body: body
      )
    }.to raise_error(described_class::Failure, /not registered/)
  end

  it "will not run permissively in production" do
    # Permissive mode exists so the service can be run locally without a provisioned
    # device. Enforced here rather than left to a deploy checklist.
    allow(described_class).to receive(:permissive?).and_call_original
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
    expect(described_class.permissive?).to be(false)
    expect(described_class.required?).to be(true)
  end
end

# The fail-open hole the security review found, and the aaguid gap beside it.
RSpec.describe AppAttest, "configuration" do
  it "refuses an assertion when the app id is missing and attestation is enforced" do
    # This used to return early and accept anything. App Attest then proved only that
    # *some* app on genuine hardware signed the request, which anybody with their own
    # entitled build can arrange.
    allow(described_class).to receive(:permissive?).and_return(false)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("APP_ATTEST_APP_ID").and_return(nil)

    digger = Digger.for_install(SecureRandom.uuid)
    digger.update!(attest_public_key: "x", attest_counter: 0)
    expect {
      described_class.send(:verify_rp_id!, "whatever")
    }.to raise_error(described_class::Failure, /not configured/)
  end

  it "skips the check only when running permissively" do
    allow(described_class).to receive_messages(permissive?: true, required?: false)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("APP_ATTEST_APP_ID").and_return(nil)
    expect { described_class.send(:verify_rp_id!, "whatever") }.not_to raise_error
  end

  describe "the authenticator stamp" do
    def auth_data_with(aaguid)
      (("\x11" * 32) + [0x40].pack("C") + [1].pack("N") + aaguid + ("\x00" * 2)).b
    end

    it "accepts Apple's production authenticator" do
      expect {
        described_class.send(:verify_aaguid!, auth_data_with(described_class::PRODUCTION_AAGUID))
      }.not_to raise_error
    end

    it "refuses a development attestation in production" do
      # A far easier bar than App Review, and the obvious way in once the relying-party
      # check is closed.
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
      expect {
        described_class.send(:verify_aaguid!, auth_data_with(described_class::DEVELOPMENT_AAGUID))
      }.to raise_error(described_class::Failure, /development attestation/)
    end

    it "allows a development attestation outside production" do
      expect {
        described_class.send(:verify_aaguid!, auth_data_with(described_class::DEVELOPMENT_AAGUID))
      }.not_to raise_error
    end

    it "refuses an authenticator it does not recognise" do
      expect {
        described_class.send(:verify_aaguid!, auth_data_with("x" * 16))
      }.to raise_error(described_class::Failure, /unrecognised/)
    end

    it "ignores an assertion, which carries no credential data" do
      short = ("\x11" * 32) + [0x40].pack("C") + [1].pack("N")
      expect { described_class.send(:verify_aaguid!, short) }.not_to raise_error
    end
  end
end

RSpec.describe AppAttest, "truncated authenticator data" do
  it "refuses an attestation that carries no credential data" do
    # The same fail-open shape as the relying-party hole: skipping a check because the
    # input was too short to run it.
    short = (("\x11" * 32) + [0x40].pack("C") + [1].pack("N")).b
    expect { described_class.send(:verify_aaguid!, short, expected: true) }
      .to raise_error(described_class::Failure, /no credential data/)
  end

  it "still allows an assertion, which has none by design" do
    short = (("\x11" * 32) + [0x40].pack("C") + [1].pack("N")).b
    expect { described_class.send(:verify_aaguid!, short, expected: false) }.not_to raise_error
  end
end
