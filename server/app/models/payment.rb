# frozen_string_literal: true

# Append-only. Nothing in the app updates or deletes one.
class Payment < ApplicationRecord
  belongs_to :digger

  validates :slab_id, presence: true, uniqueness: true
  validates :amount, numericality: { greater_than_or_equal_to: 0 }

  # §6: reject a slab that was bagged impossibly fast.
  MINIMUM_DURATION_MS = 8_000

  before_validation :set_created_at, on: :create

  scope :today, -> { where(created_at: Time.current.beginning_of_day..) }
  scope :recent_first, -> { order(created_at: :desc) }

  # Append-only (§6), enforced rather than documented. Overriding `readonly_attributes`
  # looked like it did this and did nothing at all; `attr_readonly` is the mechanism.
  attr_readonly :amount, :credited, :slab_id, :digger_id

  def flawless?
    intact >= 0.999 && exposure >= 0.999
  end

  private

  def set_created_at
    self.created_at ||= Time.current
  end
end
