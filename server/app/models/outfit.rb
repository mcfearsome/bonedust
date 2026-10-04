# frozen_string_literal: true

# A handful of diggers pooling what they pay.
class Outfit < ApplicationRecord
  has_many :diggers, dependent: :nullify
  belongs_to :founder, class_name: "Digger", optional: true

  validates :name, presence: true, uniqueness: true
  validates :join_code, presence: true, uniqueness: true

  # Unambiguous when read aloud or copied off a screen: no O/0, no I/1, no S/5.
  CODE_ALPHABET = "ABCDEFGHJKLMNPQRTUVWXY2346789"
  CODE_LENGTH = 6
  MAX_MEMBERS = 12

  # Names are generated rather than typed.
  #
  # Free text would be a content-moderation surface with no moderation behind it, on a
  # service that stores no accounts and has no way to contact anybody. Generated names
  # also cannot be squatted, impersonated, or used to carry a slur into a leaderboard that
  # every player sees. The cost is that an outfit cannot be called what its members want,
  # which is a real loss and the reason this is worth revisiting with a reject list and a
  # report path rather than left as it is.
  ADJECTIVES = %w[
    Blue Flint Cold Deep Iron Salt Low Grey Quiet Broken Patient Long Sharp Narrow
  ].freeze
  NOUNS = %w[
    Lias Shale Quarry Seam Cutting Hollow Reach Bank Drift Ridge Bed Spoil Measure
  ].freeze
  SUFFIXES = %w[
    Irregulars Company Diggers Party Outfit Hands Crew Lot Few
  ].freeze

  def self.generate_name
    12.times do
      candidate = "The #{ADJECTIVES.sample} #{NOUNS.sample} #{SUFFIXES.sample}"
      return candidate unless exists?(name: candidate)
    end
    # Astronomically unlikely; a suffix keeps it deterministic rather than looping forever.
    "The #{ADJECTIVES.sample} #{NOUNS.sample} #{SUFFIXES.sample} #{SecureRandom.hex(2)}"
  end

  def self.generate_code
    12.times do
      candidate = Array.new(CODE_LENGTH) { CODE_ALPHABET.chars.sample }.join
      return candidate unless exists?(join_code: candidate)
    end
    SecureRandom.alphanumeric(CODE_LENGTH).upcase
  end

  def self.found!(digger:)
    outfit = create!(
      name: generate_name, join_code: generate_code, founder: digger, paid_total: 0
    )
    digger.update!(outfit: outfit)
    outfit
  end

  # Same atomic shape as the crew ledger, for the same reason: two members paying at once
  # must both count.
  def self.credit!(id, amount)
    return if amount <= 0

    connection.exec_update(
      "UPDATE outfits SET paid_total = paid_total + $1, updated_at = NOW() WHERE id = $2",
      "credit_outfit",
      [amount, id]
    )
  end

  def member_count
    diggers.count
  end

  def full?
    member_count >= MAX_MEMBERS
  end

  def reached_milestones
    OutfitMilestone.in_order.select { |m| paid_total >= m.amount }
  end

  def reached_unlocks
    reached_milestones.flat_map { |m| m.unlocks + m.cosmetics }
  end

  def as_payload(include_code: false)
    {
      id: id,
      name: name,
      paid_total: paid_total,
      member_count: member_count,
      reached_unlocks: reached_unlocks,
      milestones: OutfitMilestone.in_order.map { |m| m.as_payload(paid_total) },
      join_code: include_code ? join_code : nil
    }.compact
  end
end
