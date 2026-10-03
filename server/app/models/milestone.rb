# frozen_string_literal: true

# A rung on the ladder from docs/CREW_LEDGER.md.
#
# A table rather than constants in code, so the ladder can be re-tuned with a migration
# instead of an App Store review cycle — which is the whole reason the amounts are data.
class Milestone < ApplicationRecord
  validates :key, presence: true, uniqueness: true
  validates :amount, numericality: { greater_than: 0 }

  scope :in_order, -> { order(:amount) }

  def reached?(paid)
    paid >= amount
  end

  def as_payload(paid)
    {
      key: key,
      amount: amount,
      name: name,
      beat: beat,
      unlocks: unlocks,
      cosmetics: cosmetics,
      reached: reached?(paid)
    }
  end
end
