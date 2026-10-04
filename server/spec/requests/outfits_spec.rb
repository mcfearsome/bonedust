# frozen_string_literal: true

require "rails_helper"

RSpec.describe "outfits", type: :request do
  let(:install) { SecureRandom.uuid }
  let(:headers) { { "X-Bonedust-Install" => install, "CONTENT_TYPE" => "application/json" } }

  def headers_for(id) = { "X-Bonedust-Install" => id, "CONTENT_TYPE" => "application/json" }

  def found(as: install)
    post "/v1/outfits", params: {}.to_json, headers: headers_for(as)
    JSON.parse(response.body)
  end

  # Pays at most what the slab could be worth, so specs are not flaky on the fossil drawn.
  def pay(amount, as: install)
    hdrs = headers_for(as)
    post "/v1/slabs", params: { site: "charmouth" }.to_json, headers: hdrs
    slab = JSON.parse(response.body)
    ceiling = SlabIssue.find_by!(slab_id: slab["slab_id"]).base_ceiling
    post "/v1/payments",
         params: { slab_id: slab["slab_id"], amount: [amount, ceiling].min,
                   duration_ms: 42_000, site: "charmouth", exposure: 0.9,
                   intact: 1.0 }.to_json,
         headers: hdrs
    JSON.parse(response.body).fetch("credited")
  end

  describe "founding one" do
    it "generates a name and a join code" do
      body = found
      expect(response).to have_http_status(:created)
      expect(body["name"]).to start_with("The ")
      expect(body["join_code"]).to match(/\A[A-Z2-9]{6}\z/)
      expect(body["member_count"]).to eq(1)
      expect(body["paid_total"]).to be_zero
    end

    it "never issues an ambiguous character in a code" do
      # Codes get read aloud and copied off screens; O/0 and I/1 are where that goes wrong.
      20.times { expect(Outfit.generate_code).not_to match(/[O0I1S5]/) }
    end

    it "refuses to found a second one" do
      found
      post "/v1/outfits", params: {}.to_json, headers: headers
      expect(response).to have_http_status(:conflict)
      expect(JSON.parse(response.body)["error"]).to eq("already_in_an_outfit")
    end
  end

  describe "joining" do
    it "takes a code, case-insensitively" do
      code = found["join_code"]
      mate = SecureRandom.uuid
      post "/v1/outfits/join", params: { join_code: code.downcase }.to_json,
           headers: headers_for(mate)
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["member_count"]).to eq(2)
    end

    it "refuses an unknown code" do
      post "/v1/outfits/join", params: { join_code: "ZZZZZZ" }.to_json, headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "refuses once the outfit is full" do
      outfit = Outfit.found!(digger: Digger.for_install(SecureRandom.uuid))
      (Outfit::MAX_MEMBERS - 1).times do
        Digger.for_install(SecureRandom.uuid).update!(outfit: outfit)
      end
      post "/v1/outfits/join", params: { join_code: outfit.join_code }.to_json, headers: headers
      expect(response).to have_http_status(:conflict)
      expect(JSON.parse(response.body)["error"]).to eq("outfit_full")
    end
  end

  describe "pooling what members pay" do
    it "credits the outfit in the same breath as the crew debt" do
      found
      credited = pay(10_000)
      expect(credited).to be_positive
      expect(Outfit.first.paid_total).to eq(credited)
      expect(CrewLedger.current.paid).to eq(credited)
    end

    it "adds up across members" do
      code = found["join_code"]
      mate = SecureRandom.uuid
      post "/v1/outfits/join", params: { join_code: code }.to_json, headers: headers_for(mate)

      mine = pay(10_000)
      theirs = pay(10_000, as: mate)
      expect(Outfit.first.paid_total).to eq(mine + theirs)
    end

    it "does not credit an outfit the payer is not in" do
      outfit = Outfit.found!(digger: Digger.for_install(SecureRandom.uuid))
      pay(10_000)   # a digger with no outfit
      expect(outfit.reload.paid_total).to be_zero
    end

    it "keeps what a leaver already paid" do
      # Clawing it back would let one member take a milestone away from everyone else by
      # walking out, and the crew debt cannot go backwards either.
      found
      credited = pay(10_000)
      delete "/v1/outfits/me", headers: headers
      expect(response).to have_http_status(:ok)
      expect(Outfit.first.paid_total).to eq(credited)
      expect(Digger.find_by(install_id: install).outfit_id).to be_nil
    end
  end

  describe "milestones" do
    it "reports rungs as reached and hands back their unlocks" do
      found
      outfit = Outfit.first
      first_rung = OutfitMilestone.in_order.first
      Outfit.credit!(outfit.id, first_rung.amount)

      get "/v1/outfits/me", headers: headers
      body = JSON.parse(response.body)
      expect(body["paid_total"]).to eq(first_rung.amount)
      expect(body["milestones"].first["reached"]).to be(true)
      expect(body["reached_unlocks"]).to include(*first_rung.unlocks + first_rung.cosmetics)
    end

    it "reports nothing reached for a new outfit" do
      found
      get "/v1/outfits/me", headers: headers
      body = JSON.parse(response.body)
      expect(body["reached_unlocks"]).to be_empty
      expect(body["milestones"].map { |m| m["reached"] }).to all(be(false))
    end
  end

  describe "the board" do
    it "ranks outfits by what they have paid" do
      found
      big = Outfit.first
      other = Outfit.found!(digger: Digger.for_install(SecureRandom.uuid))
      Outfit.credit!(big.id, 500)
      Outfit.credit!(other.id, 100)

      get "/v1/outfits/leaderboard", headers: headers
      entries = JSON.parse(response.body)["entries"]
      expect(entries.map { |e| e["paid_total"] }).to eq([500, 100])
      expect(entries.first["yours"]).to be(true)
    end
  end

  it "reports no outfit for someone who has not joined one" do
    get "/v1/outfits/me", headers: headers
    expect(JSON.parse(response.body)["outfit"]).to be_nil
  end
end
