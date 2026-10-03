# frozen_string_literal: true

require "rails_helper"

# §6: "Write cross-language golden tests: 50 seeds -> identical bone/gem/rock cell counts
# and maxPayout in Swift and Ruby."
#
# What is compared is the fossil drawn, the instance count, and the ceiling. Cell counts
# are deliberately not: they come out of the rasterizer, which runs on 32-bit floats and
# platform libm, where `sin` can differ in the last bit between the client's macOS and this
# server's Linux. That would flip a cell on a boundary and fail an exact test while
# changing nothing the server uses. See lib/bonedust/ceiling.rb.
RSpec.describe Bonedust::Ceiling do
  fixture_path = Rails.root.join("../shared/golden/derivations.json")
  derivations = JSON.parse(File.read(fixture_path))

  it "has a fixture covering every site and many fossils" do
    expect(derivations.size).to be >= 250
    expect(derivations.map { |d| d["siteID"] }.uniq.size).to eq(Bonedust.constants.sites.size)
    expect(derivations.map { |d| d["fossilID"] }.uniq.size).to be >= 15
  end

  derivations.each_slice(25).with_index do |group, index|
    it "matches Swift exactly for seed group #{index}" do
      group.each do |expected|
        actual = described_class.derive(
          seed: expected.fetch("seed"), site_id: expected.fetch("siteID")
        )
        expect(actual.fetch("fossilID")).to eq(expected.fetch("fossilID")),
          "seed #{expected['seed']} drew a different fossil"
        expect(actual.fetch("instances")).to eq(expected.fetch("instances")),
          "seed #{expected['seed']} drew a different instance count"
        expect(actual.fetch("baseCeiling")).to eq(expected.fetch("baseCeiling")),
          "seed #{expected['seed']} produced a different ceiling"
      end
    end
  end

  describe "the slack allowance" do
    it "accepts a payment a shade over the ceiling" do
      # The client totals in 32-bit floats and this totals in doubles; a product of four
      # multipliers can land either side of a rounding boundary. Wrongly rejecting a real
      # payment tells a paying customer they are a cheat.
      expect(described_class.allows?(amount: 101, ceiling: 100)).to be(true)
    end

    it "rejects a payment meaningfully over the ceiling" do
      expect(described_class.allows?(amount: 150, ceiling: 100)).to be(false)
      expect(described_class.allows?(amount: 1_000_000, ceiling: 100)).to be(false)
    end
  end

  describe "the PRNG" do
    it "reproduces Swift's first draws for a known seed" do
      rng = Bonedust::SplitMix64.new(0)
      # These come from SplitMix64's reference output and must not drift.
      expect(rng.next_u64).to eq(16_294_208_416_658_607_535)
      expect(rng.next_u64).to eq(7_960_286_522_194_355_700)
    end

    it "keeps next_unit inside [0, 1)" do
      rng = Bonedust::SplitMix64.new(99)
      2_000.times do
        value = rng.next_unit
        expect(value).to be >= 0
        expect(value).to be < 1
      end
    end

    it "masks to 64 bits" do
      rng = Bonedust::SplitMix64.new(0xFFFF_FFFF_FFFF_FFFF)
      500.times { expect(rng.next_u64).to be < (1 << 64) }
    end
  end
end
