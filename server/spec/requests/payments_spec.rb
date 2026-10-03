# frozen_string_literal: true

require "rails_helper"

RSpec.describe "POST /v1/payments", type: :request do
  let(:install) { SecureRandom.uuid }
  let(:headers) { { "X-Bonedust-Install" => install, "CONTENT_TYPE" => "application/json" } }

  def issue_slab(site: "charmouth")
    post "/v1/slabs", params: { site: site }.to_json, headers: headers
    expect(response).to have_http_status(:created)
    JSON.parse(response.body)
  end

  def pay(slab, amount:, duration_ms: 42_000, **extra)
    body = {
      slab_id: slab["slab_id"], amount: amount, duration_ms: duration_ms,
      site: slab["site"], exposure: 0.9, intact: 1.0, gems: 0
    }.merge(extra)
    post "/v1/payments", params: body.to_json, headers: headers
    JSON.parse(response.body)
  end

  it "credits the crew debt and reports the new remaining" do
    slab = issue_slab
    body = pay(slab, amount: 90)
    expect(response).to have_http_status(:created)
    expect(body["credited"]).to eq(90)
    expect(CrewLedger.current.paid).to eq(90)
    expect(body["remaining"]).to eq(CrewLedger.current.remaining)
  end

  it "rejects a slab bagged impossibly fast" do
    slab = issue_slab
    body = pay(slab, amount: 50, duration_ms: 3_000)
    expect(response).to have_http_status(:unprocessable_content)
    expect(body["error"]).to eq("too_fast")
    expect(CrewLedger.current.paid).to be_zero
  end

  it "rejects an amount above what that seed could possibly have paid" do
    slab = issue_slab
    body = pay(slab, amount: 999_999)
    expect(response).to have_http_status(:unprocessable_content)
    expect(body["error"]).to eq("implausible")
    expect(body["ceiling"]).to be_positive
    expect(CrewLedger.current.paid).to be_zero
  end

  it "accepts a payment right at the ceiling" do
    slab = issue_slab
    issue = SlabIssue.find_by!(slab_id: slab["slab_id"])
    pay(slab, amount: issue.base_ceiling)
    expect(response).to have_http_status(:created)
  end

  it "treats a retry of the same slab as the same payment" do
    # The client's offline queue retries anything it did not get an answer for, including
    # requests that in fact succeeded. A retry must not double-count or error.
    slab = issue_slab
    pay(slab, amount: 70)
    expect(CrewLedger.current.paid).to eq(70)

    body = pay(slab, amount: 70)
    expect(response).to have_http_status(:ok)
    expect(body["duplicate"]).to be(true)
    expect(CrewLedger.current.paid).to eq(70), "a retry double-counted"
    expect(Payment.count).to eq(1)
  end

  it "cannot be replayed with a different amount" do
    slab = issue_slab
    pay(slab, amount: 70)
    pay(slab, amount: 900)
    expect(CrewLedger.current.paid).to eq(70)
  end

  it "will not let one digger spend another's slab" do
    slab = issue_slab
    other = { "X-Bonedust-Install" => SecureRandom.uuid, "CONTENT_TYPE" => "application/json" }
    post "/v1/payments",
         params: { slab_id: slab["slab_id"], amount: 90, duration_ms: 42_000,
                   site: "charmouth" }.to_json,
         headers: other
    # It falls through to the offline path, which still checks the seed it names -- and it
    # names none, so the ceiling is zero.
    expect(response).to have_http_status(:unprocessable_content)
    expect(CrewLedger.current.paid).to be_zero
  end

  describe "offline slabs" do
    it "credits half, and still checks the ceiling" do
      derived = Bonedust::Ceiling.derive(seed: 12_345, site_id: "charmouth")
      post "/v1/payments",
           params: { slab_id: SecureRandom.uuid, amount: 80, duration_ms: 42_000,
                     seed: "12345", site: "charmouth",
                     fossil_id: derived["fossilID"], exposure: 0.9, intact: 1.0 }.to_json,
           headers: headers
      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body["offline"]).to be(true)
      expect(body["credited"]).to eq(40), "an offline slab counts at half"
      expect(CrewLedger.current.paid).to eq(40)
    end

    it "rejects an implausible offline amount" do
      post "/v1/payments",
           params: { slab_id: SecureRandom.uuid, amount: 500_000, duration_ms: 42_000,
                     seed: "12345", site: "charmouth" }.to_json,
           headers: headers
      expect(response).to have_http_status(:unprocessable_content)
      expect(CrewLedger.current.paid).to be_zero
    end

    it "rejects an offline payment that names no seed" do
      post "/v1/payments",
           params: { slab_id: SecureRandom.uuid, amount: 10, duration_ms: 42_000,
                     site: "charmouth" }.to_json,
           headers: headers
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  it "raises a claimed charm's ceiling, but not without limit" do
    slab = issue_slab
    issue = SlabIssue.find_by!(slab_id: slab["slab_id"])
    expect(issue.ceiling_for(%w[provenance_papers gem_cradle])).to be > issue.base_ceiling
    # Claiming more charms than there are slots must not keep raising it.
    four = issue.ceiling_for(%w[provenance_papers gem_cradle compound_interest collectors_loupe])
    six = issue.ceiling_for(%w[provenance_papers gem_cradle compound_interest collectors_loupe
                               diamond_sieve steady_lamp])
    expect(six).to eq(four)
  end

  it "rate limits an install to 120 payments an hour" do
    120.times { RateLimiter.check!("payments:#{install}") }
    expect { RateLimiter.check!("payments:#{install}") }
      .to raise_error(RateLimiter::Exceeded) { |e| expect(e.retry_after).to be_positive }
  end

  it "requires an install id" do
    post "/v1/payments", params: {}.to_json, headers: { "CONTENT_TYPE" => "application/json" }
    expect(response).to have_http_status(:unauthorized)
  end

  it "refuses a malformed install id" do
    post "/v1/slabs", params: { site: "charmouth" }.to_json,
         headers: { "X-Bonedust-Install" => "not-a-uuid", "CONTENT_TYPE" => "application/json" }
    expect(response).to have_http_status(:unauthorized)
  end

  it "refuses an unknown site" do
    post "/v1/slabs", params: { site: "atlantis" }.to_json, headers: headers
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "records a flawless slab for the leaderboard" do
    slab = issue_slab
    pay(slab, amount: 50, exposure: 1.0, intact: 1.0)
    expect(Digger.find_by(install_id: install).flawless_slabs).to eq(1)
  end

  it "never changes a payment once written" do
    # Asserts the property, not the mechanism: whether Rails raises or silently ignores
    # the assignment, what matters is that the stored row cannot move.
    slab = issue_slab
    pay(slab, amount: 50)
    payment = Payment.first
    begin
      payment.update(amount: 5_000)
    rescue ActiveRecord::ReadonlyAttributeError
      # Either outcome is acceptable.
    end
    expect(Payment.first.amount).to eq(50)
  end

  it "issues a seed as a string, because JSON numbers lose the top bits" do
    slab = issue_slab
    expect(slab["seed"]).to be_a(String)
    expect(slab["seed"].to_i).to be_positive
  end
end
