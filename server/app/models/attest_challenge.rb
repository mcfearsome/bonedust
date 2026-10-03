# frozen_string_literal: true

class AttestChallenge < ApplicationRecord
  validates :nonce, presence: true, uniqueness: true
  validates :install_id, presence: true
end
