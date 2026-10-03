# frozen_string_literal: true

module V1
  # GET /v1/me — your lifetime share and where it puts you.
  class MeController < ApplicationController
    def show
      ledger = CrewLedger.current
      render json: {
        install_id: digger.install_id,
        display_name: digger.display_name,
        paid_total: digger.paid_total,
        paid_season: digger.paid_season,
        best_slab_amount: digger.best_slab_amount,
        flawless_slabs: digger.flawless_slabs,
        # Rank by a count of who is strictly ahead, which is one index scan rather than a
        # window function over every digger.
        rank: Digger.where("paid_total > ?", digger.paid_total).count + 1,
        diggers: Digger.where("paid_total > 0").count,
        share_of_paid: ledger.paid.zero? ? 0.0 : digger.paid_total.to_f / ledger.paid
      }
    end

    # PATCH /v1/me — opt in or out of showing a name.
    #
    # The Game Center alias is the only name this service stores, it is sent only when the
    # player chooses to, and clearing it is always available.
    def update
      name = params[:display_name].to_s.strip
      digger.update!(display_name: name.empty? ? nil : name.first(32))
      render json: { display_name: digger.display_name }
    end
  end
end
