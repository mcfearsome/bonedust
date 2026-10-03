# frozen_string_literal: true

# A season is a calendar quarter (docs/CREW_LEDGER.md).
#
# Derived rather than stored, so there is no scheduled job to forget and no row to go
# stale. Only the season board resets; `paid_total` and the debt never do.
module Season
  module_function

  def key(at = Time.current)
    time = at.utc
    "#{time.year}-Q#{((time.month - 1) / 3) + 1}"
  end

  def started_at(at = Time.current)
    time = at.utc
    month = (((time.month - 1) / 3) * 3) + 1
    Time.utc(time.year, month, 1)
  end
end
