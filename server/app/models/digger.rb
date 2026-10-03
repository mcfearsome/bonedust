# frozen_string_literal: true

# One install. There are no accounts (§2), only a UUID from the Keychain.
class Digger < ApplicationRecord
  has_many :payments, dependent: :restrict_with_exception
  has_many :slab_issues, dependent: :destroy

  validates :install_id, presence: true, uniqueness: true

  def self.for_install(install_id)
    # find_or_create_by races under concurrency; the unique index decides the winner and
    # the retry picks them up.
    find_or_create_by!(install_id: install_id)
  rescue ActiveRecord::RecordNotUnique
    find_by!(install_id: install_id)
  end

  # The name shown on the ledger feed and the boards. Anonymous unless the player chose
  # to send their Game Center alias.
  def public_name
    display_name.presence || "A digger"
  end
end
