class RemoveBranchFromAiTasks < ActiveRecord::Migration[8.1]
  # Branch isn't a runner concern — the prompt itself tells Claude to
  # switch / create branches. Drop the unused column.
  def change
    remove_column :ai_tasks, :branch, :string
  end
end
