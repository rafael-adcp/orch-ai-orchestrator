class AddEffortToAiTasks < ActiveRecord::Migration[8.1]
  def change
    add_column :ai_tasks, :effort, :string
  end
end
