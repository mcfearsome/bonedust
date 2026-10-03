# frozen_string_literal: true

# The ledger row and the milestone ladder have to exist for any request spec to mean
# anything, and `db:prepare` does not run seeds for the test database.
module LedgerSeed
  LEDGER_PATH = Rails.root.join("../shared/ledger.json")

  def self.ensure!
    definition = JSON.parse(File.read(LEDGER_PATH))
    ledger = CrewLedger.find_or_initialize_by(id: CrewLedger::SINGLETON_ID)
    ledger.total_debt = definition.fetch("totalDebt")
    ledger.new_game_plus_debt = definition.fetch("newGamePlusDebt")
    ledger.paid = 0
    ledger.save!
    definition.fetch("milestones").each do |row|
      Milestone.find_or_initialize_by(key: row.fetch("id")).update!(
        amount: row.fetch("amount"), name: row.fetch("name"), beat: row["beat"],
        unlocks: row.fetch("unlocks", []), cosmetics: row.fetch("cosmetics", [])
      )
    end
  end

  # Empties every table between examples.
  #
  # Done this way rather than with transactional fixtures because the payment path opens
  # its own transaction and issues a raw UPDATE; wrapping each example in an outer
  # transaction would hide exactly the behaviour this service exists to get right.
  def self.reset!
    tables = %w[payments slab_issues attest_challenges diggers milestones crew_ledgers
                rate_counters]
    ActiveRecord::Base.connection.execute(
      "TRUNCATE #{tables.join(', ')} RESTART IDENTITY CASCADE"
    )
  end
end

RSpec.configure do |config|
  config.before do
    LedgerSeed.reset!
    Rails.cache.clear
    LedgerSeed.ensure!
  end
end
