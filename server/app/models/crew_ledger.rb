# frozen_string_literal: true

# The one row.
class CrewLedger < ApplicationRecord
  SINGLETON_ID = 1

  def self.current
    find(SINGLETON_ID)
  end

  # Adds to `paid` and returns the new total, in one statement.
  #
  # This is §6's requirement and the reason the load test exists. Read-modify-write in
  # Ruby would lose increments under concurrency no matter how the transaction is
  # isolated; `UPDATE ... SET paid = paid + $1 RETURNING paid` cannot, because the row
  # lock is held by the statement itself.
  #
  # If write contention on one row ever becomes the bottleneck, the fix is sharded
  # counter rows summed on read. It is not needed at this scale and the brief says so.
  def self.credit!(amount)
    raise ArgumentError, "amount must be positive" unless amount.positive?

    result = connection.exec_query(
      "UPDATE crew_ledgers SET paid = paid + $1, updated_at = NOW() WHERE id = $2 RETURNING paid",
      "credit_crew_ledger",
      [amount, SINGLETON_ID]
    )
    raise ActiveRecord::RecordNotFound, "crew ledger row missing" if result.rows.empty?

    result.rows.first.first.to_i
  end

  def remaining
    [total_debt - paid, 0].max
  end

  def fraction_paid
    return 0.0 if total_debt.zero?

    [paid.to_f / total_debt, 1.0].min
  end
end
