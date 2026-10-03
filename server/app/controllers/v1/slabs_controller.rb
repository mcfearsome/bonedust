# frozen_string_literal: true

module V1
  # POST /v1/slabs — issues the seed a slab is dug from (§6).
  #
  # Issuing the seed server-side is what makes a payment checkable at all: the server can
  # recompute what that slab could possibly have been worth. A client that digs offline
  # generates its own seed and is credited a fraction instead.
  class SlabsController < ApplicationController
    def create
      attest!
      site_id = params.require(:site)
      unless Bonedust.constants.site(site_id)
        return render json: { error: "unknown_site" }, status: :unprocessable_entity
      end

      issue = SlabIssue.issue!(digger: digger, site_id: site_id)
      render json: {
        slab_id: issue.slab_id,
        # A string, not a number: seeds exceed what JSON numbers carry safely and a
        # client parsing 2^53+ as a double would dig a different slab than the one the
        # server scored.
        seed: issue.seed.to_s,
        site: issue.site_id,
        issued_at: issue.issued_at.iso8601
      }, status: :created
    end
  end
end
