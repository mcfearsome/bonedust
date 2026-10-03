# frozen_string_literal: true

require "bonedust/ceiling"

# A slab the server handed out, and the ceiling it computed from the seed.
class SlabIssue < ApplicationRecord
  belongs_to :digger

  # Seeds are issued below 2^62 so they fit a signed bigint without a numeric column.
  SEED_LIMIT = 1 << 62

  validates :slab_id, presence: true, uniqueness: true
  validates :seed, numericality: { greater_than_or_equal_to: 0, less_than: SEED_LIMIT }

  def self.issue!(digger:, site_id:)
    seed = SecureRandom.random_number(SEED_LIMIT)
    derived = Bonedust::Ceiling.derive(seed: seed, site_id: site_id)
    create!(
      slab_id: SecureRandom.uuid,
      digger: digger,
      seed: seed,
      site_id: site_id,
      fossil_id: derived.fetch("fossilID"),
      instances: derived.fetch("instances"),
      base_ceiling: derived.fetch("baseCeiling"),
      issued_at: Time.current
    )
  end

  # The ceiling for this slab given the charms the client claims to hold.
  def ceiling_for(claimed_charms)
    constants = Bonedust.constants
    fossil = constants.fossil(fossil_id)
    site = constants.site(site_id)
    return base_ceiling if fossil.nil? || site.nil?

    Bonedust::Ceiling.ceiling(
      fossil: fossil, instances: instances, site: site,
      claimed_charms: Array(claimed_charms), constants: constants
    )
  end
end
