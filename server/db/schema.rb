# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 2026_10_03_000001) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "attest_challenges", force: :cascade do |t|
    t.string "install_id", null: false
    t.string "nonce", null: false
    t.datetime "expires_at", null: false
    t.datetime "consumed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_attest_challenges_on_expires_at"
    t.index ["nonce"], name: "index_attest_challenges_on_nonce", unique: true
  end

  create_table "crew_ledgers", force: :cascade do |t|
    t.bigint "total_debt", null: false
    t.bigint "paid", default: 0, null: false
    t.bigint "new_game_plus_debt", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "diggers", force: :cascade do |t|
    t.string "install_id", null: false
    t.string "display_name"
    t.string "attest_key_id"
    t.binary "attest_public_key"
    t.bigint "attest_counter", default: 0, null: false
    t.bigint "paid_total", default: 0, null: false
    t.bigint "paid_season", default: 0, null: false
    t.string "season_key"
    t.integer "best_slab_amount", default: 0, null: false
    t.integer "best_streak", default: 0, null: false
    t.integer "flawless_slabs", default: 0, null: false
    t.datetime "last_payment_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["attest_key_id"], name: "index_diggers_on_attest_key_id", unique: true
    t.index ["best_slab_amount"], name: "index_diggers_on_best_slab_amount", order: :desc
    t.index ["best_streak"], name: "index_diggers_on_best_streak", order: :desc
    t.index ["flawless_slabs"], name: "index_diggers_on_flawless_slabs", order: :desc
    t.index ["install_id"], name: "index_diggers_on_install_id", unique: true
    t.index ["paid_season"], name: "index_diggers_on_paid_season", order: :desc
    t.index ["paid_total"], name: "index_diggers_on_paid_total", order: :desc
  end

  create_table "milestones", force: :cascade do |t|
    t.string "key", null: false
    t.bigint "amount", null: false
    t.string "name", null: false
    t.text "beat"
    t.jsonb "unlocks", default: [], null: false
    t.jsonb "cosmetics", default: [], null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["amount"], name: "index_milestones_on_amount"
    t.index ["key"], name: "index_milestones_on_key", unique: true
  end

  create_table "payments", force: :cascade do |t|
    t.bigint "digger_id", null: false
    t.string "slab_id", null: false
    t.integer "amount", null: false
    t.integer "credited", null: false
    t.string "fossil_id"
    t.string "site_id"
    t.integer "duration_ms", default: 0, null: false
    t.float "exposure", default: 0.0, null: false
    t.float "intact", default: 0.0, null: false
    t.integer "gems", default: 0, null: false
    t.boolean "offline", default: false, null: false
    t.string "season_key"
    t.datetime "created_at", null: false
    t.index ["created_at"], name: "index_payments_on_created_at"
    t.index ["digger_id", "created_at"], name: "index_payments_on_digger_id_and_created_at"
    t.index ["digger_id"], name: "index_payments_on_digger_id"
    t.index ["slab_id"], name: "index_payments_on_slab_id", unique: true
  end

  create_table "rate_counters", force: :cascade do |t|
    t.string "bucket", null: false
    t.integer "count", default: 0, null: false
    t.datetime "window_started_at", null: false
    t.index ["bucket"], name: "index_rate_counters_on_bucket", unique: true
  end

  create_table "slab_issues", force: :cascade do |t|
    t.string "slab_id", null: false
    t.bigint "digger_id", null: false
    t.bigint "seed", null: false
    t.string "site_id", null: false
    t.string "fossil_id", null: false
    t.integer "instances", default: 1, null: false
    t.integer "base_ceiling", default: 0, null: false
    t.datetime "issued_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["digger_id"], name: "index_slab_issues_on_digger_id"
    t.index ["issued_at"], name: "index_slab_issues_on_issued_at"
    t.index ["slab_id"], name: "index_slab_issues_on_slab_id", unique: true
  end

  add_foreign_key "payments", "diggers"
  add_foreign_key "slab_issues", "diggers"
end
