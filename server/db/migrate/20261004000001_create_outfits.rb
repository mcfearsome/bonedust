# frozen_string_literal: true

class CreateOutfits < ActiveRecord::Migration[8.0]
  def change
    # A handful of diggers who pool what they pay.
    #
    # "Crew" already means every player alive against one debt, so the smaller group gets
    # its own word. An outfit is what a survey party was called.
    create_table :outfits do |t|
      t.string :name, null: false
      # Short, shareable, and the only way in. There are no accounts (§2), so a code is
      # the whole of membership.
      t.string :join_code, null: false
      t.bigint :paid_total, null: false, default: 0
      t.references :founder, foreign_key: { to_table: :diggers }
      t.timestamps
    end
    add_index :outfits, :join_code, unique: true
    add_index :outfits, :paid_total, order: { paid_total: :desc }
    # Names are generated, not typed, so they are unique by construction and worth
    # enforcing — two outfits with the same name would make the join code the only way to
    # tell them apart in a leaderboard.
    add_index :outfits, :name, unique: true

    add_reference :diggers, :outfit, foreign_key: true
    add_index :diggers, %i[outfit_id paid_total]

    create_table :outfit_milestones do |t|
      t.string :key, null: false
      t.bigint :amount, null: false
      t.string :name, null: false
      t.text :beat
      t.jsonb :unlocks, null: false, default: []
      t.jsonb :cosmetics, null: false, default: []
      t.timestamps
    end
    add_index :outfit_milestones, :key, unique: true
    add_index :outfit_milestones, :amount
  end
end
