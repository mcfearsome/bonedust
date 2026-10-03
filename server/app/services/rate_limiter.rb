# frozen_string_literal: true

# §6: 120 payments per install per hour.
#
# A database row rather than an in-process counter, because the limit has to hold across
# several web processes and survive a restart. One row per bucket, incremented atomically
# and reset when its window has rolled over.
class RateLimiter
  class Exceeded < StandardError
    attr_reader :retry_after

    def initialize(retry_after)
      @retry_after = retry_after
      super("rate limit exceeded")
    end
  end

  WINDOW = 1.hour
  PAYMENTS_PER_WINDOW = 120

  def self.check!(bucket, limit: PAYMENTS_PER_WINDOW, window: WINDOW)
    now = Time.current
    result = ActiveRecord::Base.connection.exec_query(<<~SQL.squish, "rate_limit", [bucket, now, window.to_i])
      INSERT INTO rate_counters (bucket, count, window_started_at)
      VALUES ($1, 1, $2)
      ON CONFLICT (bucket) DO UPDATE SET
        count = CASE
          WHEN rate_counters.window_started_at < $2 - ($3 || ' seconds')::interval THEN 1
          ELSE rate_counters.count + 1
        END,
        window_started_at = CASE
          WHEN rate_counters.window_started_at < $2 - ($3 || ' seconds')::interval THEN $2
          ELSE rate_counters.window_started_at
        END
      RETURNING count, window_started_at
    SQL

    count, started_at = result.rows.first
    return true if count.to_i <= limit

    elapsed = now - (started_at.is_a?(String) ? Time.zone.parse(started_at) : started_at)
    raise Exceeded, [(window - elapsed).to_i, 1].max
  end
end
