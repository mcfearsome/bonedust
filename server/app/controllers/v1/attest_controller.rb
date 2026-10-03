# frozen_string_literal: true

module V1
  class AttestController < ApplicationController
    # A fresh one-shot nonce. The client signs it along with the request body, which is
    # what stops a captured payment from being replayed.
    def challenge
      challenge = AppAttest.issue_challenge(install_id)
      render json: { nonce: challenge.nonce, expires_at: challenge.expires_at.iso8601 }
    end

    # Registers the device's Secure Enclave key.
    def register
      AppAttest.register!(
        digger: digger,
        key_id: params.require(:key_id),
        attestation: params.require(:attestation),
        challenge_nonce: params.require(:challenge),
        request_body: request.raw_post
      )
      render json: { registered: true }
    end
  end
end
