# frozen_string_literal: true

require_relative "split_mix64"
require_relative "constants"

module Bonedust
  # The server half of §6's plausibility check, ported from
  # Sources/BonedustCore/Economy/ServerCeiling.swift.
  #
  # What it reproduces exactly: the fossil a seed draws, how many copies, and the most
  # that slab could pay. All three come from integer PRNG draws and arithmetic on
  # constants, which port without loss.
  #
  # What it deliberately does not reproduce: bone, rock and gem *cell counts*. Those come
  # out of the rasterizer, which runs on 32-bit floats and platform libm, and `sin` can
  # differ in the last bit between the client's macOS and this server's Linux — enough to
  # flip a cell on a boundary and fail an exact comparison for no benefit. The ceiling
  # does not need them, so they are not ported and not tested.
  module Ceiling
    CHARM_SLOTS = 4
    TOOL_SLOTS = 3

    module_function

    # Replays the first two PRNG draws of slab generation.
    def derive(seed:, site_id:, constants: Bonedust.constants)
      site = constants.site(site_id) or raise ArgumentError, "unknown site #{site_id}"
      rng = SplitMix64.new(seed)

      # Draw 1: the fossil. The weight table is sorted by id, because a Hash has no
      # defined order and relying on JSON order would make a content reorder silently
      # change every historical slab.
      table = site.fetch("fossilWeights").sort_by { |id, _| id }
      fossil_id = table.empty? ? nil : table.last.first
      unless table.empty?
        total = table.sum { |_, weight| weight }
        roll = rng.next_int_below(total)
        table.each do |id, weight|
          roll -= weight
          if roll.negative?
            fossil_id = id
            break
          end
        end
      end
      fossil = constants.fossil(fossil_id) || constants.fossils.values.first

      # Draw 2: how many copies.
      extra = site.dig("modifiers", "extraInstances") || 0
      min = fossil.fetch("instancesMin", 1)
      max = [min, fossil.fetch("instancesMax", 1) + extra].max
      instances = rng.next_int(min, through: max)

      {
        "seed" => seed,
        "siteID" => site_id,
        "fossilID" => fossil.fetch("id"),
        "instances" => instances,
        "baseCeiling" => ceiling(
          fossil: fossil, instances: instances, site: site,
          claimed_charms: [], constants: constants
        )
      }
    end

    # The most a slab could pay, given the charms the client claims to hold.
    #
    # Claimed charms are taken at face value and capped at the charm slots. A client can
    # raise its own ceiling by lying about its loadout, but it cannot invent money, and
    # verifying ownership would mean this service tracking every run. §6 asks for
    # proportionate, not paranoid.
    def ceiling(fossil:, instances:, site:, claimed_charms:, constants: Bonedust.constants)
      tuning = constants.tuning
      charms = claimed_charms.first(CHARM_SLOTS).filter_map { |id| constants.charm(id) }

      payout_multiplier = 1.0
      gem_multiplier = 1.0
      rush_multiplier = 1.0
      nodule_payout = 0
      flat_bonus = 0

      fold = lambda do |modifiers|
        next if modifiers.nil?

        payout_multiplier *= (modifiers["payoutMultiplier"] || 1.0)
        gem_multiplier *= (modifiers["gemMultiplier"] || 1.0)
        rush_multiplier *= (modifiers["rushMultiplier"] || 1.0)
        nodule_payout += (modifiers["rockNodulePayout"] || 0)
        flat_bonus += (modifiers["flatBonus"] || 0)
      end

      fold.call(site_modifier_set(site))
      charms.each do |charm|
        fold.call(charm["modifiers"])
        # Scaling is computed in double on both sides, so it is NOT narrowed here.
        scaling = charm["scaling"]
        next if scaling.nil?

        value = scaling.fetch("value").to_f
        case scaling.fetch("kind")
        when "payoutPerCharm" then payout_multiplier *= 1 + value * CHARM_SLOTS
        when "payoutPerTool" then payout_multiplier *= 1 + value * TOOL_SLOTS
        when "payoutPerBankedGem"
          payout_multiplier *= 1 + value * (tuning.fetch("gemsMax") * 5)
        end
      end
      # Assume every skeleton set is complete.
      constants.sets.each do |set|
        fold.call(perk_modifier_set(set.fetch("perk"), site.fetch("id")))
      end

      fossil_pay = (fossil.fetch("baseValue") * [1, instances].max).to_f
      gems = (tuning.fetch("gemsMax") * tuning.fetch("gemValue")).to_f * gem_multiplier
      # Best possible grade, as with everything else here: a slab cleared, unbroken and
      # bagged early earns gradeBonusS on top of fossil and gem money. A ceiling that
      # ignored it would reject the exact slab a player is proudest of, at the moment the
      # dig went perfectly -- the worst possible time to accuse somebody of cheating.
      # Mirrors ServerCeiling.ceiling; the two move together or golden_spec fails.
      # A first find too, as every other term here assumes its best case -- otherwise the
      # first specimen of a species, the most memorable slab a player digs, is rejected as
      # a forgery. Mirrors ServerCeiling.ceiling; the two move together or golden_spec fails.
      # And the best price any buyer pays. The fence pays 2.1x, and a ceiling that did not
      # know would reject the sale the moment a player took the money.
      best_buyer = constants.buyers.map { |b| b.fetch("priceMultiplier") }.max || 1.0
      multiplier = payout_multiplier * rush_multiplier *
        (1 + tuning.fetch("gradeBonusS")) * tuning.fetch("firstFindMultiplier") * best_buyer
      scaled = ((fossil_pay + gems) * multiplier).round

      nodules = tuning.fetch("rockNodulesMax") + (site.dig("modifiers", "extraRockNodules") || 0)
      [0, scaled + nodules * nodule_payout + flat_bonus].max
    end

    # Does the server accept this amount?
    #
    # One percent plus a dollar of slack. The client totals its payout in 32-bit floats
    # and this does it in doubles; a product of four multipliers can land either side of a
    # rounding boundary. A dollar costs nothing. Wrongly rejecting a real payment tells a
    # paying customer they are a cheat.
    def allows?(amount:, ceiling:)
      amount <= (ceiling * 1.01).round + 1
    end

    # SiteModifiers.modifierSet: only the fields that behave like a charm.
    def site_modifier_set(site)
      modifiers = site["modifiers"] || {}
      {
        "payoutMultiplier" => modifiers["payoutMultiplier"] || 1.0,
        "gemMultiplier" => 1.0,
        "rushMultiplier" => 1.0
      }
    end

    # SetPerk.modifiers(forSite:).
    #
    # The `f32` calls matter: Swift computes `1 + value` in Float here before the ceiling
    # widens it to Double, so doing the addition in double would land on a different
    # number. Only operations Swift performs in Float get narrowed.
    def perk_modifier_set(perk, site_id)
      required = perk["siteID"]
      return nil if required && required != site_id

      value = perk.fetch("value")
      case perk.fetch("kind")
      when "sitePayoutBonus" then { "payoutMultiplier" => Constants.f32(1 + value) }
      when "gemBonus" then { "gemMultiplier" => Constants.f32(1 + value) }
      else nil
      end
    end
  end

  def self.constants
    @constants ||= Constants.load
  end
end
