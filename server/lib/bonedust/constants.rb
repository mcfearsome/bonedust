# frozen_string_literal: true

require "json"

module Bonedust
  # Loads shared/constants.json, the file Swift generates with `make constants`.
  #
  # Every float is narrowed to 32 bits on the way in. That is the load-bearing line in
  # this file: Swift's content types store `Float`, so Swift sees 1.6 as
  # 1.60000002384185791015625 while Ruby would see 1.6000000000000000888... Narrowing
  # here makes both sides start from the same number, which is what lets the ceiling
  # arithmetic agree to the dollar instead of to within a dollar.
  class Constants
    DEFAULT_PATH = File.expand_path("../../../shared/constants.json", __dir__)

    attr_reader :tuning, :fossils, :sites, :tools, :charms, :sets, :buyers

    def self.load(path = DEFAULT_PATH)
      new(JSON.parse(File.read(path)))
    end

    # Narrows a number to IEEE single precision, the way Swift's decoder does.
    def self.f32(value)
      return nil if value.nil?

      [value.to_f].pack("f").unpack1("f")
    end

    def initialize(raw)
      @raw = raw
      @tuning = deep_f32(raw.fetch("tuning"))
      @fossils = index(raw.fetch("fossils", []))
      @sites = index(raw.fetch("sites", []))
      @tools = index(raw.fetch("tools", []))
      @charms = index(raw.fetch("charms", []))
      @sets = raw.fetch("sets", []).map { |s| deep_f32(s) }
      # Needed for the ceiling: a buyer's priceMultiplier is the last term in what a slab
      # can legitimately pay, and the fence pays 2.1x.
      @buyers = raw.fetch("buyers", []).map { |b| deep_f32(b) }
      # Read, not redeclared. These bound the per-charm and per-tool ceilings, so a belt
      # that widens on the client has to widen here in the same commit or honest play is
      # rejected as forgery.
      @charm_slots = raw.fetch("charmSlots")
      @tool_slots = raw.fetch("toolSlots")
      freeze
    end

    def fossil(id) = @fossils[id]
    def site(id) = @sites[id]
    def charm(id) = @charms[id]
    def charm_slots = @charm_slots
    def tool_slots = @tool_slots

    def schema = @raw["schema"]

    private

    def index(list)
      list.each_with_object({}) { |item, out| out[item.fetch("id")] = deep_f32(item) }.freeze
    end

    # Narrows every float in a nested structure. Integers are left alone: narrowing them
    # to Float32 would lose precision above 2^24 for no reason.
    def deep_f32(node)
      case node
      when Float then Constants.f32(node)
      when Hash then node.transform_values { |v| deep_f32(v) }.freeze
      when Array then node.map { |v| deep_f32(v) }.freeze
      else node
      end
    end
  end
end
