# frozen_string_literal: true

module V1
  # POST /v1/payments — the only endpoint that moves the debt.
  class PaymentsController < ApplicationController
    # docs/CREW_LEDGER.md: a slab dug without a server-issued seed counts at half. Zero
    # would punish playing on a plane, which the brief wants supported; full credit would
    # make the plausibility check pointless, since a cheat would simply claim to be offline.
    OFFLINE_CREDIT_FRACTION = 0.5

    def create
      RateLimiter.check!("payments:#{install_id}")
      attest!

      slab_id = params.require(:slab_id).to_s
      amount = params.require(:amount).to_i
      duration_ms = params[:duration_ms].to_i

      # Checked up front, not left to the exception path. The offline queue retries
      # anything it did not get an answer for, so a repeat is an ordinary event rather
      # than an error, and answering it with the payment that already exists is what makes
      # the queue safe to retry. The unique index and the rescue below still cover two
      # retries arriving at the same instant.
      if (existing = Payment.find_by(slab_id: slab_id))
        return render json: payment_payload(existing).merge(duplicate: true), status: :ok
      end

      return reject("negative_amount") if amount.negative?
      # §6: nobody bags a slab in under eight seconds.
      return reject("too_fast") if duration_ms < Payment::MINIMUM_DURATION_MS

      issue = SlabIssue.find_by(slab_id: slab_id, digger_id: digger.id)
      offline = issue.nil?
      ceiling = offline ? offline_ceiling : issue.ceiling_for(claimed_charms)
      return reject("implausible", ceiling: ceiling) unless
        Bonedust::Ceiling.allows?(amount: amount, ceiling: ceiling)

      credited = offline ? (amount * OFFLINE_CREDIT_FRACTION).round : amount
      payment = record_payment(slab_id: slab_id, amount: amount, credited: credited,
                               offline: offline, duration_ms: duration_ms, issue: issue)
      render json: payment_payload(payment), status: :created
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      # Two retries landing together. The unique index decided which one won; the loser
      # reports the winner's payment.
      existing = Payment.find_by(slab_id: params[:slab_id].to_s)
      raise e if existing.nil?

      render json: payment_payload(existing).merge(duplicate: true), status: :ok
    end

    private

    def claimed_charms
      Array(params[:charms]).map(&:to_s).first(4)
    end

    # An offline slab still has a checkable ceiling: the client reports the seed it used,
    # and the server derives from it exactly as it would from one it issued.
    def offline_ceiling
      seed = params[:seed].to_s
      site_id = params[:site].to_s
      return 0 if seed.empty? || Bonedust.constants.site(site_id).nil?

      derived = Bonedust::Ceiling.derive(seed: seed.to_i, site_id: site_id)
      fossil = Bonedust.constants.fossil(derived.fetch("fossilID"))
      Bonedust::Ceiling.ceiling(
        fossil: fossil,
        instances: derived.fetch("instances"),
        site: Bonedust.constants.site(site_id),
        claimed_charms: claimed_charms
      )
    end

    def record_payment(slab_id:, amount:, credited:, offline:, duration_ms:, issue:)
      payment = nil
      Payment.transaction do
        payment = Payment.create!(
          digger: digger,
          slab_id: slab_id,
          amount: amount,
          credited: credited,
          fossil_id: params[:fossil_id].presence || issue&.fossil_id,
          site_id: params[:site].presence || issue&.site_id,
          duration_ms: duration_ms,
          exposure: params[:exposure].to_f,
          intact: params[:intact].to_f,
          gems: params[:gems].to_i,
          offline: offline,
          season_key: Season.key
        )
        # §6: the atomic increment happens in the same transaction as the insert, so the
        # debt and the payments table can never disagree. The outfit's total moves in the
        # same breath and the same way, for the same reason: two members paying at once
        # must both count.
        if credited.positive?
          CrewLedger.credit!(credited)
          Outfit.credit!(digger.outfit_id, credited) if digger.outfit_id
        end
        update_rollup(payment)
      end
      payment
    end

    # The leaderboard rollup, written in the same transaction. Boards read this instead of
    # aggregating payments, which is what keeps a top-100 read an index scan.
    #
    # Written as one UPDATE with bind parameters rather than read-modify-write, for the
    # same reason the ledger increment is: two payments landing together must both count.
    def update_rollup(payment)
      season = Season.key
      ActiveRecord::Base.connection.exec_update(<<~SQL.squish, "digger_rollup", [
        UPDATE diggers SET
          paid_total = paid_total + $1,
          paid_season = CASE WHEN season_key IS DISTINCT FROM $2 THEN $1 ELSE paid_season + $1 END,
          season_key = $2,
          best_slab_amount = GREATEST(best_slab_amount, $3),
          flawless_slabs = flawless_slabs + $4,
          last_payment_at = NOW(),
          updated_at = NOW()
        WHERE id = $5
      SQL
        payment.credited.to_i,
        season,
        payment.amount.to_i,
        payment.flawless? ? 1 : 0,
        digger.id
      ])
      digger.reload
    end

    def payment_payload(payment)
      ledger = CrewLedger.current
      {
        slab_id: payment.slab_id,
        amount: payment.amount,
        credited: payment.credited,
        offline: payment.offline,
        remaining: ledger.remaining,
        paid: ledger.paid,
        your_total: digger.paid_total
      }
    end

    def reject(code, extra = {})
      render json: { error: code }.merge(extra), status: :unprocessable_entity
    end
  end
end
