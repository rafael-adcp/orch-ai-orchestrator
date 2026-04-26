class CreateAiTasks < ActiveRecord::Migration[8.1]
  def change
    create_table :ai_tasks, id: :string, limit: 12 do |t|
      t.string  :provider,   null: false, default: "claude" # claude | copilot | ...
      t.string  :status,     null: false, default: "pending"
      t.string  :repo_path,  null: false
      t.text    :prompt,     null: false
      t.string  :branch
      t.string  :model
      t.string  :docker_cmd
      t.integer :priority,   null: false, default: 0
      t.string  :log_path
      t.text    :error
      t.string  :solid_queue_job_id
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end
    add_index :ai_tasks, :status
    add_index :ai_tasks, [ :status, :priority, :created_at ]
    add_index :ai_tasks, :provider
  end
end
