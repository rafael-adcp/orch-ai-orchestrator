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

ActiveRecord::Schema[8.1].define(version: 2026_05_01_300000) do
  create_table "ai_tasks", id: { type: :string, limit: 12 }, force: :cascade do |t|
    t.string "active_job_id"
    t.datetime "created_at", null: false
    t.string "docker_cmd"
    t.string "effort"
    t.text "error"
    t.datetime "finished_at"
    t.string "log_path"
    t.string "model"
    t.string "outcome", default: "in_flight", null: false
    t.integer "priority", default: 0, null: false
    t.text "prompt", null: false
    t.string "provider", default: "claude", null: false
    t.integer "recurring_interval_hours"
    t.string "repo_path", null: false
    t.datetime "started_at"
    t.datetime "updated_at", null: false
    t.index ["active_job_id"], name: "index_ai_tasks_on_active_job_id"
    t.index ["outcome", "priority", "created_at"], name: "index_ai_tasks_on_outcome_and_priority_and_created_at"
    t.index ["outcome"], name: "index_ai_tasks_on_outcome"
    t.index ["provider"], name: "index_ai_tasks_on_provider"
  end
end
