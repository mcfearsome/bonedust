# frozen_string_literal: true

# Seeds the ledger from shared/ledger.json, which is the same file the app ships so the
# milestone track renders offline (docs/CREW_LEDGER.md).
#
# Idempotent: safe to run on every deploy. Amounts are upserted rather than inserted, so
# re-tuning the ladder is a migration-and-seed, not a data-repair exercise.

LEDGER_PATH = Rails.root.join("../shared/ledger.json")
definition = JSON.parse(File.read(LEDGER_PATH))

ledger = CrewLedger.find_or_initialize_by(id: CrewLedger::SINGLETON_ID)
ledger.total_debt = definition.fetch("totalDebt")
ledger.new_game_plus_debt = definition.fetch("newGamePlusDebt")
ledger.paid ||= 0
ledger.save!

definition.fetch("milestones").each do |row|
  Milestone.find_or_initialize_by(key: row.fetch("id")).update!(
    amount: row.fetch("amount"),
    name: row.fetch("name"),
    beat: row["beat"],
    unlocks: row.fetch("unlocks", []),
    cosmetics: row.fetch("cosmetics", [])
  )
end

# Anything removed from the file is removed here too, so a re-tune cannot leave a
# milestone the client will never see referenced in the database.
Milestone.where.not(key: definition.fetch("milestones").map { |m| m.fetch("id") }).delete_all

puts "ledger seeded: $#{ledger.total_debt} debt, #{Milestone.count} milestones"
