class AddRetryScheduledToAiTasks < ActiveRecord::Migration[8.1]
  def change
    add_column :ai_tasks, :retry_at, :datetime
  end
end
