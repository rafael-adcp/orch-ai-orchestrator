class AddRecurringIntervalHoursToAiTasks < ActiveRecord::Migration[8.1]
  def change
    add_column :ai_tasks, :recurring_interval_hours, :integer
  end
end
