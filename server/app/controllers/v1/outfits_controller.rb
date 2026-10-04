# frozen_string_literal: true

module V1
  # Outfits: a handful of diggers pooling what they pay.
  class OutfitsController < ApplicationController
    # POST /v1/outfits — found one. The name is generated; see Outfit for why.
    def create
      attest!
      return conflict("already_in_an_outfit") if digger.outfit_id.present?

      outfit = Outfit.found!(digger: digger)
      render json: outfit.as_payload(include_code: true), status: :created
    end

    # POST /v1/outfits/join
    def join
      attest!
      return conflict("already_in_an_outfit") if digger.outfit_id.present?

      code = params.require(:join_code).to_s.strip.upcase
      outfit = Outfit.find_by(join_code: code)
      return render json: { error: "unknown_code" }, status: :not_found if outfit.nil?
      return conflict("outfit_full") if outfit.full?

      digger.update!(outfit: outfit)
      render json: outfit.as_payload(include_code: true)
    end

    # GET /v1/outfits/me
    def show
      outfit = digger.outfit
      return render json: { outfit: nil } if outfit.nil?

      render json: outfit.as_payload(include_code: true).merge(
        your_share: outfit.paid_total.zero? ? 0.0
          : digger.paid_total.to_f / outfit.paid_total,
        members: outfit.diggers.order(paid_total: :desc).limit(Outfit::MAX_MEMBERS).map { |d|
          { name: d.public_name, paid_total: d.paid_total, you: d.id == digger.id }
        }
      )
    end

    # DELETE /v1/outfits/me — leave.
    #
    # What the outfit has already paid stays with the outfit. Clawing it back on departure
    # would mean a member could take a milestone away from everyone else by walking out,
    # and the crew debt itself can never go backwards either.
    def leave
      attest!
      return render json: { outfit: nil } if digger.outfit_id.nil?

      digger.update!(outfit: nil)
      render json: { outfit: nil, left: true }
    end

    # GET /v1/outfits/leaderboard
    def leaderboard
      top = Outfit.where("paid_total > 0").order(paid_total: :desc, id: :asc).limit(100)
      render json: {
        entries: top.each_with_index.map { |outfit, index|
          {
            rank: index + 1,
            name: outfit.name,
            paid_total: outfit.paid_total,
            member_count: outfit.member_count,
            yours: outfit.id == digger.outfit_id
          }
        }
      }
    end

    private

    def conflict(code)
      render json: { error: code }, status: :conflict
    end
  end
end
