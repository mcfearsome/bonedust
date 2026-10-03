# frozen_string_literal: true

module V1
  # GET /v1/leaderboard — top 100 plus your own neighbourhood.
  #
  # Every board is derived from the rollup that the validated payment path writes. There
  # is no endpoint that accepts a score, which is the one rule in docs/CREW_LEDGER.md: a
  # client-submitted score would be a second, unprotected way in.
  class LeaderboardController < ApplicationController
    BOARDS = {
      "contribution" => { column: :paid_total, unit: "dollars" },
      "season" => { column: :paid_season, unit: "dollars" },
      "best_slab" => { column: :best_slab_amount, unit: "dollars" },
      "streak" => { column: :best_streak, unit: "runs" },
      "intact" => { column: :flawless_slabs, unit: "count" }
    }.freeze

    TOP = 100
    NEIGHBOURS = 5

    def index
      board = BOARDS[params[:board].to_s] || BOARDS["contribution"]
      column = board[:column]
      scope = Digger.where("#{column} > 0")
      scope = scope.where(season_key: Season.key) if column == :paid_season

      top = scope.order(column => :desc, id: :asc).limit(TOP)
      render json: {
        board: params[:board].presence || "contribution",
        unit: board[:unit],
        entries: top.each_with_index.map { |d, i| entry(d, i + 1, column) },
        # At rank forty thousand a bare top-100 tells you nothing. Your own
        # neighbourhood is the part worth coming back for.
        around_you: neighbourhood(scope, column)
      }
    end

    private

    def entry(other, rank, column)
      {
        rank: rank,
        name: other.public_name,
        value: other.public_send(column),
        you: other.id == digger.id
      }
    end

    def neighbourhood(scope, column)
      mine = digger.public_send(column).to_i
      return [] if mine.zero?

      rank = scope.where("#{column} > ?", mine).count + 1
      return [] if rank <= TOP

      window = scope.order(column => :desc, id: :asc)
                    .offset([rank - NEIGHBOURS - 1, 0].max)
                    .limit((NEIGHBOURS * 2) + 1)
      start = [rank - NEIGHBOURS, 1].max
      window.each_with_index.map { |d, i| entry(d, start + i, column) }
    end
  end
end
