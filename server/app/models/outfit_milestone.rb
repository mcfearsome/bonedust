# frozen_string_literal: true

# A rung on the outfit ladder. Seeded from shared/ledger.json, like the crew's.
class OutfitMilestone < ApplicationRecord
  validates :key, presence: true, uniqueness: true
  validates :amount, numericality: { greater_than: 0 }

  scope :in_order, -> { order(:amount) }

  def as_payload(paid)
    {
      key: key, amount: amount, name: name, beat: beat,
      unlocks: unlocks, cosmetics: cosmetics, reached: paid >= amount
    }
  end
end
