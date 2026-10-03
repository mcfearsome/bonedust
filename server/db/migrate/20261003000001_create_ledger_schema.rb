# frozen_string_literal: true

class CreateLedgerSchema < ActiveRecord::Migration[8.0]
  def change
    # The crew debt. Exactly one row, ever.
    #
    # §6 wants the increment done with an atomic `UPDATE ... RETURNING` inside the same
    # transaction as the payment insert, which is what keeps 500 concurrent payments from
    # losing any of them. Amounts are whole dollars in a bigint: the game has no cents,
    # and $2.4 billion is nowhere near the limit.
    create_table :crew_ledgers do |t|
      t.bigint :total_debt, null: false
      t.bigint :paid, null: false, default: 0
      t.bigint :new_game_plus_debt, null: false, default: 0
      t.timestamps
    end

    create_table :diggers do |t|
      # The install UUID from the Keychain. There are no accounts (§2).
      t.string :install_id, null: false
      # Opt-in Game Center alias. The only name this service ever stores.
      t.string :display_name
      t.string :attest_key_id
      t.binary :attest_public_key
      t.bigint :attest_counter, null: false, default: 0
      t.bigint :paid_total, null: false, default: 0
      t.bigint :paid_season, null: false, default: 0
      t.string :season_key
      t.integer :best_slab_amount, null: false, default: 0
      t.integer :best_streak, null: false, default: 0
      t.integer :flawless_slabs, null: false, default: 0
      t.datetime :last_payment_at
      t.timestamps
    end
    add_index :diggers, :install_id, unique: true
    add_index :diggers, :attest_key_id, unique: true
    # One index per leaderboard sort key, so a board read is a top-100 index scan and
    # never a sequential pass over payments.
    add_index :diggers, :paid_total, order: { paid_total: :desc }
    add_index :diggers, :paid_season, order: { paid_season: :desc }
    add_index :diggers, :best_slab_amount, order: { best_slab_amount: :desc }
    add_index :diggers, :best_streak, order: { best_streak: :desc }
    add_index :diggers, :flawless_slabs, order: { flawless_slabs: :desc }

    # Slabs the server issued. The seed is what makes the payment checkable.
    create_table :slab_issues do |t|
      t.string :slab_id, null: false
      t.references :digger, null: false, foreign_key: true
      # Signed bigint on purpose: seeds are issued in 0..2^62 so they fit without a
      # numeric column, and 4.6 quintillion slabs is enough.
      t.bigint :seed, null: false
      t.string :site_id, null: false
      t.string :fossil_id, null: false
      t.integer :instances, null: false, default: 1
      # The plausibility ceiling, computed at issue time from the seed alone.
      t.integer :base_ceiling, null: false, default: 0
      t.datetime :issued_at, null: false
      t.timestamps
    end
    add_index :slab_issues, :slab_id, unique: true
    add_index :slab_issues, :issued_at

    # Append-only (§6). Never updated, never deleted.
    create_table :payments do |t|
      t.references :digger, null: false, foreign_key: true
      t.string :slab_id, null: false
      t.integer :amount, null: false
      t.integer :credited, null: false
      t.string :fossil_id
      t.string :site_id
      t.integer :duration_ms, null: false, default: 0
      t.float :exposure, null: false, default: 0
      t.float :intact, null: false, default: 0
      t.integer :gems, null: false, default: 0
      # Dug without a server-issued seed. Credited at a fraction (docs/CREW_LEDGER.md).
      t.boolean :offline, null: false, default: false
      t.string :season_key
      t.datetime :created_at, null: false
    end
    # The thing that makes a replayed payment impossible rather than merely unlikely.
    add_index :payments, :slab_id, unique: true
    add_index :payments, :created_at
    add_index :payments, %i[digger_id created_at]

    create_table :milestones do |t|
      t.string :key, null: false
      t.bigint :amount, null: false
      t.string :name, null: false
      t.text :beat
      t.jsonb :unlocks, null: false, default: []
      t.jsonb :cosmetics, null: false, default: []
      t.timestamps
    end
    add_index :milestones, :key, unique: true
    add_index :milestones, :amount

    # Rate limiting, 120 payments per install per hour (§6). A table rather than an
    # in-process counter so it survives a restart and works across several web processes.
    create_table :rate_counters do |t|
      t.string :bucket, null: false
      t.integer :count, null: false, default: 0
      t.datetime :window_started_at, null: false
    end
    add_index :rate_counters, :bucket, unique: true

    # Attestation challenges, one-shot, so an assertion cannot be replayed.
    create_table :attest_challenges do |t|
      t.string :install_id, null: false
      t.string :nonce, null: false
      t.datetime :expires_at, null: false
      t.datetime :consumed_at
      t.timestamps
    end
    add_index :attest_challenges, :nonce, unique: true
    add_index :attest_challenges, :expires_at
  end
end
