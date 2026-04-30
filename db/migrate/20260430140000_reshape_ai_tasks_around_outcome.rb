class ReshapeAiTasksAroundOutcome < ActiveRecord::Migration[8.1]
  # Solid Queue is the source of truth for execution mechanics
  # (queued / running / scheduled-retry / failed-with-attempts-left).
  # AiTask only owns the application-level outcome of a finished run:
  # done, failed, blocked, needs_review, cancelled — or in_flight while
  # SQ is still working it. We track active_job_id (stable across retries)
  # so the presenter can find the latest SQ row for this lineage.
  def up
    remove_index  :ai_tasks, name: "index_ai_tasks_on_status_and_priority_and_created_at"
    remove_index  :ai_tasks, name: "index_ai_tasks_on_status"
    remove_column :ai_tasks, :status
    remove_column :ai_tasks, :retry_at
    remove_column :ai_tasks, :solid_queue_job_id

    add_column :ai_tasks, :outcome,       :string, null: false, default: "in_flight"
    add_column :ai_tasks, :active_job_id, :string
    add_index  :ai_tasks, :outcome
    add_index  :ai_tasks, [ :outcome, :priority, :created_at ]
    add_index  :ai_tasks, :active_job_id
  end

  def down
    remove_index  :ai_tasks, :active_job_id
    remove_index  :ai_tasks, [ :outcome, :priority, :created_at ]
    remove_index  :ai_tasks, :outcome
    remove_column :ai_tasks, :active_job_id
    remove_column :ai_tasks, :outcome

    add_column :ai_tasks, :solid_queue_job_id, :string
    add_column :ai_tasks, :retry_at,           :datetime
    add_column :ai_tasks, :status,             :string, null: false, default: "pending"
    add_index  :ai_tasks, :status
    add_index  :ai_tasks, [ :status, :priority, :created_at ]
  end
end
