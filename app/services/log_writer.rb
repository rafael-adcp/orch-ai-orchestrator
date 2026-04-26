# Tiny seam over file I/O so ClaudeRunner doesn't touch the filesystem
# directly. Tests inject a fake (in-memory hash) instead of writing to disk.
class LogWriter
  def initialize(root: Rails.root.join("log", "tasks"))
    @root = root
  end

  def path_for(task_id)
    File.join(@root, "#{task_id}.log")
  end

  def write_header(path, header)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, header)
  end

  def append(path, chunk)
    File.open(path, "a") { |f| f.write(chunk); f.flush }
  end
end
