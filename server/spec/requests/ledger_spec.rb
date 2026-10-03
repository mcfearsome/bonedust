# frozen_string_literal: true

require "rails_helper"

RSpec.describe "the ledger endpoints", type: :request do
  let(:install) { SecureRandom.uuid }
  let(:headers) { { "X-Bonedust-Install" => install, "CONTENT_TYPE" => "application/json" } }

  # Pays at most what the issued slab could possibly be worth.
  #
  # A fixed amount would make these specs flaky: the ceiling depends on which fossil the
  # seed drew, and $120 is fine for an ichthyosaur paddle and implausible for a belemnite.
  # Returns what was actually credited so assertions can be about ordering rather than
  # about numbers the spec does not control.
  def pay(amount, install_id: install, exposure: 0.9, intact: 1.0)
    hdrs = { "X-Bonedust-Install" => install_id, "CONTENT_TYPE" => "application/json" }
    post "/v1/slabs", params: { site: "charmouth" }.to_json, headers: hdrs
    slab = JSON.parse(response.body)
    ceiling = SlabIssue.find_by!(slab_id: slab["slab_id"]).base_ceiling
    post "/v1/payments",
         params: { slab_id: slab["slab_id"], amount: [amount, ceiling].min,
                   duration_ms: 42_000, site: "charmouth",
                   exposure: exposure, intact: intact }.to_json,
         headers: hdrs
    expect(response).to have_http_status(:created)
    JSON.parse(response.body).fetch("credited")
  end

  describe "GET /v1/ledger" do
    it "reports the debt and the milestone ladder" do
      get "/v1/ledger", headers: headers
      body = JSON.parse(response.body)
      expect(body["total_debt"]).to eq(2_400_000_000)
      expect(body["remaining"]).to eq(2_400_000_000)
      expect(body["milestones"].size).to eq(12)
      expect(body["milestones"].first["reached"]).to be(false)
      expect(body["season"]).to match(/\A\d{4}-Q[1-4]\z/)
    end

    it "serves an ETag and answers a matching one with 304" do
      # §6 asks for a 15 second cache with an ETag. The client polls every 30 seconds
      # while a ledger screen is up, so nearly every poll should cost a 304.
      get "/v1/ledger", headers: headers
      etag = response.headers["ETag"]
      expect(etag).to be_present

      get "/v1/ledger", headers: headers.merge("If-None-Match" => etag)
      expect(response).to have_http_status(:not_modified)
      expect(response.body).to be_empty
    end

    it "marks a milestone reached once the crew has paid it" do
      CrewLedger.credit!(1_000_000)
      Rails.cache.clear
      get "/v1/ledger", headers: headers
      first = JSON.parse(response.body)["milestones"].first
      expect(first["key"]).to eq("first_page")
      expect(first["reached"]).to be(true)
      expect(first["unlocks"]).to include("site:hell_creek")
    end

    it "shows the recent feed anonymously until a name is offered" do
      pay(60)
      Rails.cache.clear
      get "/v1/ledger", headers: headers
      feed = JSON.parse(response.body)["recent"]
      expect(feed.first["name"]).to eq("A digger")
      expect(feed.first["amount"]).to eq(60)
    end

    it "uses an offered name in the feed" do
      pay(60)
      patch "/v1/me", params: { display_name: "Mary Anning" }.to_json, headers: headers
      Rails.cache.clear
      get "/v1/ledger", headers: headers
      expect(JSON.parse(response.body)["recent"].first["name"]).to eq("Mary Anning")
    end
  end

  describe "GET /v1/me" do
    it "reports your share and rank" do
      credited = pay(10_000)   # clamped to what the slab could be worth
      get "/v1/me", headers: headers
      body = JSON.parse(response.body)
      expect(body["paid_total"]).to eq(credited)
      expect(body["rank"]).to eq(1)
      expect(body["share_of_paid"]).to be_within(0.001).of(1.0)
    end

    it "lets a player take their name back off" do
      patch "/v1/me", params: { display_name: "Mary Anning" }.to_json, headers: headers
      patch "/v1/me", params: { display_name: "" }.to_json, headers: headers
      expect(JSON.parse(response.body)["display_name"]).to be_nil
    end
  end

  describe "GET /v1/leaderboard" do
    it "ranks by the rollup the payment path wrote" do
      big = SecureRandom.uuid
      small = SecureRandom.uuid
      more = pay(10_000, install_id: big)   # clamped to the slab's ceiling
      less = pay(5, install_id: small)
      expect(more).to be > less

      get "/v1/leaderboard", params: { board: "contribution" }, headers: headers
      entries = JSON.parse(response.body)["entries"]
      expect(entries.map { |e| e["value"] }).to eq([more, less])
      expect(entries.first["rank"]).to eq(1)
      expect(entries.last["rank"]).to eq(2)
    end

    it "marks which row is yours" do
      pay(50)
      get "/v1/leaderboard", headers: headers
      expect(JSON.parse(response.body)["entries"].find { |e| e["you"] }).to be_present
    end

    it "has a board for flawless slabs fed by the same path" do
      pay(40, exposure: 1.0, intact: 1.0)
      get "/v1/leaderboard", params: { board: "intact" }, headers: headers
      body = JSON.parse(response.body)
      expect(body["unit"]).to eq("count")
      expect(body["entries"].first["value"]).to eq(1)
    end

    it "falls back to contribution for an unknown board" do
      pay(10)
      get "/v1/leaderboard", params: { board: "nonsense" }, headers: headers
      expect(JSON.parse(response.body)["unit"]).to eq("dollars")
    end

    it "offers no way to submit a score" do
      # The one rule in docs/CREW_LEDGER.md: every board is derived from validated
      # payments. A score-submission endpoint would be a second, unprotected way in, and
      # the first thing anybody would attack.
      post "/v1/leaderboard", params: {}.to_json, headers: headers
      expect(response).to have_http_status(:not_found)
      expect(Rails.application.routes.routes.map { |r| r.path.spec.to_s })
        .not_to include(a_string_matching(%r{leaderboard.*POST}i))
    end
  end
end
