# frozen_string_literal: true

class ApplicationController < ActionController::API
  class Unauthorized < StandardError; end

  rescue_from AppAttest::Failure do |error|
    render json: { error: "attestation_failed", detail: error.message }, status: :unauthorized
  end

  rescue_from Unauthorized do |error|
    render json: { error: "unauthorized", detail: error.message }, status: :unauthorized
  end

  rescue_from ActionController::ParameterMissing do |error|
    render json: { error: "missing_parameter", detail: error.message }, status: :bad_request
  end

  rescue_from ActiveRecord::RecordInvalid do |error|
    render json: { error: "invalid", detail: error.message }, status: :unprocessable_entity
  end

  rescue_from RateLimiter::Exceeded do |error|
    response.headers["Retry-After"] = error.retry_after.to_s
    render json: { error: "rate_limited", retry_after: error.retry_after },
           status: :too_many_requests
  end

  private

  # §2: no accounts. A random UUID generated on first launch and kept in the Keychain is
  # the whole of identity.
  def install_id
    value = request.headers["X-Bonedust-Install"].to_s
    raise Unauthorized, "missing or malformed install id" unless
      value.match?(/\A[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\z/)

    value
  end

  def digger
    @digger ||= Digger.for_install(install_id)
  end

  # Verifies the App Attest assertion on a mutating request.
  def attest!
    AppAttest.verify_assertion!(
      digger: digger,
      assertion: request.headers["X-Bonedust-Assertion"].to_s,
      challenge_nonce: request.headers["X-Bonedust-Challenge"].to_s,
      request_body: request.raw_post
    )
  end
end
