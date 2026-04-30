# Tiny seam over file I/O so ClaudeRunner doesn't touch the filesystem
# directly. Tests inject a fake (in-memory hash) instead of writing to disk.
#
# Always opens files in append mode so retry attempts add to the same log
# instead of clobbering the previous run. Each call to `event` prefixes an
# ISO-8601 timestamp; raw subprocess output goes through `append` unchanged.
class LogWriter
  class WriteError < StandardError; end

  def initialize(root: Rails.root.join("log", "tasks"), clock: Time)
    @root, @clock = root, clock
  end

  def path_for(task_id)
    File.join(@root, "#{task_id}.log")
  end

  def ensure_dir(path)
    FileUtils.mkdir_p(File.dirname(path))
  rescue SystemCallError => e
    raise WriteError, "cannot create log directory for #{path}: #{e.message}"
  end

  def event(path, message)
    ensure_dir(path)
    write(path, "[#{@clock.current.utc.iso8601}] #{message}\n")
  end

  def append(path, chunk)
    write(path, chunk)
  end

  private

  def write(path, content)
    File.open(path, "a") { |f| f.write(content); f.flush }
  rescue SystemCallError => e
    raise WriteError, "cannot append to log #{path}: #{e.message}"
  end
end
