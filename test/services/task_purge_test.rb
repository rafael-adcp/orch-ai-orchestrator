require "test_helper"

class TaskPurgeTest < ActiveSupport::TestCase
  setup do
    @log_dir = Rails.root.join("tmp", "purge-test-logs")
    FileUtils.mkdir_p(@log_dir)
  end

  teardown { FileUtils.remove_entry(@log_dir) if File.directory?(@log_dir) }

  def task_with_log(extras = {})
    log = @log_dir.join("#{SecureRandom.hex(3)}.log").to_s
    File.write(log, "stuff")
    AiTask.create!({ repo_path: "/tmp/r", prompt: "p", log_path: log }.merge(extras))
  end

  test "deletes a finished task, its row, and its log file" do
    task = task_with_log(outcome: AiTask::DONE, finished_at: Time.current)
    log_path = task.log_path

    result = TaskPurge.delete(task)

    assert result.deleted?
    refute AiTask.exists?(task.id)
    refute File.exist?(log_path), "log file should be removed"
  end

  test "discards a queued SQ job before deleting an in-flight task" do
    task = AiTask.create!(repo_path: "/tmp/r", prompt: "p")
    presenter = Struct.new(:running, :discarded) do
      def running? = running
      def discard_queued_job
        self.discarded = true
      end
    end.new(false, false)
    task.define_singleton_method(:status) { presenter }

    result = TaskPurge.delete(task)

    assert result.deleted?
    assert presenter.discarded, "queued SQ job should be discarded"
    refute AiTask.exists?(task.id)
  end

  test "refuses to delete a task that is currently running" do
    task = AiTask.create!(repo_path: "/tmp/r", prompt: "p")
    presenter = Class.new do
      def running? = true
      def discard_queued_job = raise("must not discard a running job")
    end.new
    task.define_singleton_method(:status) { presenter }

    result = TaskPurge.delete(task)

    refute result.deleted?
    assert_match(/running/i, result.reason)
    assert AiTask.exists?(task.id), "row must survive a refused delete"
  end

  test "tolerates a missing log file (delete proceeds anyway)" do
    task = task_with_log(outcome: AiTask::FAILED, finished_at: Time.current)
    File.delete(task.log_path)

    result = TaskPurge.delete(task)

    assert result.deleted?
    refute AiTask.exists?(task.id)
  end

  test "no log_path on the row is fine" do
    task = AiTask.create!(repo_path: "/tmp/r", prompt: "p", outcome: AiTask::DONE, finished_at: Time.current)

    result = TaskPurge.delete(task)

    assert result.deleted?
  end
end
