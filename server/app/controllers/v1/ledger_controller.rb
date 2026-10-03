# frozen_string_literal: true

module V1
  # GET /v1/ledger — what the title card and the Crew Ledger screen read.
  #
  # Cached for 15 seconds behind an ETag (§6). The client polls every 30 seconds while a
  # ledger screen is visible, so with a few hundred thousand installs this is the only
  # endpoint under real load, and almost all of it should be a 304.
  class LedgerController < ApplicationController
    CACHE_TTL = 15.seconds

    def show
      payload = Rails.cache.fetch("ledger/v1", expires_in: CACHE_TTL) { build_payload }
      # Weak ETag over the cached body: two clients polling within the same window get
      # the same tag and the second gets a 304 without touching Postgres.
      return head :not_modified if stale_check_passes?(payload)

      response.headers["Cache-Control"] = "public, max-age=#{CACHE_TTL.to_i}"
      response.headers["ETag"] = etag_for(payload)
      render json: payload
    end

    private

    def stale_check_passes?(payload)
      request.headers["If-None-Match"].to_s.split(/\s*,\s*/).include?(etag_for(payload))
    end

    def etag_for(payload)
      %(W/"#{Digest::MD5.hexdigest(payload.to_json)}")
    end

    def build_payload
      ledger = CrewLedger.current
      {
        total_debt: ledger.total_debt,
        paid: ledger.paid,
        remaining: ledger.remaining,
        new_game_plus_debt: ledger.new_game_plus_debt,
        milestones: Milestone.in_order.map { |m| m.as_payload(ledger.paid) },
        diggers_season: Digger.where(season_key: Season.key).count,
        paid_today: Payment.today.sum(:credited),
        season: Season.key,
        recent: recent_feed
      }
    end

    # The feed on the Crew Ledger screen. Names only where the player opted in.
    def recent_feed
      Payment.recent_first.limit(12).includes(:digger).map do |payment|
        {
          name: payment.digger.public_name,
          amount: payment.credited,
          fossil_id: payment.fossil_id,
          at: payment.created_at.iso8601
        }
      end
    end
  end
end
