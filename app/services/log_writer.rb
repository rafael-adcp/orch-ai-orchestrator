# Tiny seam over file I/O so ClaudeRunner doesn't touch the filesystem
# directly. Tests inject a fake (in-memory hash) instead of writing to disk.
class LogWriter
  # Domain error so callers don't have to know about Errno::* internals.
  class WriteError < StandardError; end

  def initialize(root: Rails.root.join("log", "tasks"))
    @root = root
  end

  def path_for(task_id)
    File.join(@root, "#{task_id}.log")
  end

  def write_header(path, header)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, header)
  rescue SystemCallError => e
    raise WriteError, "cannot write log header to #{path}: #{e.message}"
  end

  def append(path, chunk)
    File.open(path, "a") { |f| f.write(chunk); f.flush }
  rescue SystemCallError => e
    raise WriteError, "cannot append to log #{path}: #{e.message}"
  end
end
