# frozen_string_literal: true

Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  namespace :v1 do
    # App Attest (§6).
    get "attest/challenge", to: "attest#challenge"
    post "attest/register", to: "attest#register"

    # The seed a slab is dug from.
    post "slabs", to: "slabs#create"

    # The only endpoint that moves the debt.
    post "payments", to: "payments#create"

    get "ledger", to: "ledger#show"

    get "me", to: "me#show"
    patch "me", to: "me#update"

    get "leaderboard", to: "leaderboard#index"

    # Outfits: a handful of diggers pooling what they pay.
    post "outfits", to: "outfits#create"
    post "outfits/join", to: "outfits#join"
    get "outfits/me", to: "outfits#show"
    delete "outfits/me", to: "outfits#leave"
    get "outfits/leaderboard", to: "outfits#leaderboard"
  end
end
