# Rails + Solid Queue Port — Plan

Big-bang cutover from the Python/Prefect orchestrator
(`C:\Users\Rafael Prado\Desktop\repos\orchestrador`) to a Rails 8 app at
`C:\Users\Rafael Prado\Desktop\repos\orchestrator-rails`.

---

## 0. Decisions locked in

| | |
|---|---|
| Location | `C:\Users\Rafael Prado\Desktop\repos\orchestrator-rails` |
| Rails | 8.x (Solid Queue + Solid Cable bundled, Mission Control optional gem) |
| Ruby | 3.3.x (latest stable that Rails 8 supports) |
| DB | SQLite (one file each for primary, queue, cache) |
| UI | Mission Control + a `Tasks#index/new/show` page; **no live tail** |
| CLI | dropped — web-only |
| Cutover | big-bang: stop Python, run Rails |
| Methodology | **Sandi Metz / POOD + outside-in e2e workflow — non-negotiable** |

---

## 0.5. Methodology — Sandi Metz POOD + e2e-first (READ BEFORE CODING)

Every section below is implemented under these rules. They are not suggestions;
they are the design contract for this port. If a step in §12 conflicts with
this section, **this section wins**.

### 0.5.1 Sandi Metz / POOD rules we follow

From *Practical Object-Oriented Design in Ruby* (POODR) and the "Rules" talk:

1. **Classes ≤ 100 lines.** If `ClaudeRunner` grows past that, extract a
   collaborator (e.g. `SubprocessStreamer`, `LimitDetector`, `LogWriter`).
2. **Methods ≤ 5 lines.** No exceptions for `if/else` — extract.
3. **≤ 4 parameters per method** (hash options count individually). Use
   keyword args; inject collaborators via the constructor.
4. **Controllers instantiate one object and send it one message.** The
   `TasksController#create` action builds a `ClaudeTask` and calls
   `enqueue!` — that's the ceiling.
5. **Depend on roles, not classes.** `ClaudeRunner` takes a
   `command_builder:` and a `clock:` — both are duck-typed. Tests pass
   fakes; production passes the real ones. No `Kernel#system`,
   no `Time.now`, no `ENV[...]` reached for inside a service object.
6. **Tell, don't ask.** `task.enqueue!` not `if task.pending? then enqueue(task)`.
7. **Single responsibility per class.** The split in §4 is deliberate:
   - `ClaudeCommand` — argv assembly, nothing else.
   - `ClaudeRunner` — orchestrates one task's execution.
   - `RunClaudeJob` — Solid Queue boundary (retry policy, concurrency key).
   - `ClaudeTask` — persistence + scopes only; **no** business logic
     beyond `enqueue!`.
   If a new requirement doesn't fit one of those, add a new class — don't
   widen an existing one.
8. **Inject the world.** Subprocess spawning, filesystem writes, and clock
   reads are injected. The runner never touches `IO.popen` directly in
   tests — it goes through a `Subprocess` role object whose default
   implementation wraps `IO.popen`.
9. **No mocks of types you don't own.** We do not mock `IO`, `Process`, or
   `ActiveRecord`. We wrap them in our own seam (a thin role) and fake the
   seam.
10. **Refactor on the third occurrence (rule of three).** Don't pre-extract.
    `ClaudeCommand` exists today because there are already two argv-shape
    cases (plain + docker); a third would justify a builder hierarchy.

### 0.5.2 Outside-in e2e-first workflow

We write tests **outside-in**, starting from a failing end-to-end system
test, and only drop one layer down when the current layer forces us to.
This is the same loop GOOS / Sandi's "transition from procedural to OO"
talk describes.

**The loop, per feature slice:**

1. **Red e2e.** Write a failing system test in `test/system/` that exercises
   the feature through the real HTTP stack (`Capybara` + headless driver,
   or `ActionDispatch::IntegrationTest` if no JS is needed). The test
   stubs only the **outermost** I/O seam — the `Subprocess` role — with
   the argv-driven fake (`test/support/fake_claude.rb`). Everything else
   is real: real DB, real Solid Queue inline adapter, real controllers,
   real views.
2. **Run it.** Watch it fail with a useful message. If the failure is
   "NoMethodError on nil", the test is too coarse — make it more specific
   first.
3. **Drop one level.** The e2e failure points at a missing class or method.
   Write a focused unit test for *that* class only, using fakes for its
   collaborators. Make it green. Climb back up.
4. **Re-run the e2e.** It should now fail one step further along. Repeat
   §0.5.2.3 until the e2e is green.
5. **Refactor under green.** Apply the rules in §0.5.1. Extract collaborators,
   shrink methods, rename. The unit tests for extracted classes are written
   *during* the extraction, not before — POODR ch. 9 ("Designing Cost-Effective
   Tests"): test the messages a class sends and receives, not its internals.
6. **Commit.** One feature slice = one commit, with the e2e test in it.

**Test pyramid for this project (concrete shape):**

```
       ┌──────────────────────────┐
       │  test/system/  (≈5 tests)│  ← outside-in driver, real stack
       ├──────────────────────────┤
       │  test/jobs/    (≈3 tests)│  ← Solid Queue boundaries: retry, concurrency
       │  test/services/(≈8 tests)│  ← ClaudeRunner, ClaudeCommand — pure unit
       │  test/models/  (≈3 tests)│  ← scopes, validations
       └──────────────────────────┘
```

No controller tests, no view tests — those are covered by the system
tests above them. No tests for `ApplicationRecord` or framework code.

**Seams we own (the only places we mock):**

| Seam | Role / class | Real impl | Test fake |
|---|---|---|---|
| Subprocess spawn + stream | `Subprocess` (duck type: `#run(argv, cwd:, on_line:)`) | `IO.popen` wrapper | `FakeClaude` reading scripted argv → stdout lines |
| Clock | `clock:` (responds to `#current`) | `Time` | `Struct.new(:current)` frozen |
| Command builder | `ClaudeCommand` | itself | itself (it's already pure) |

If you find yourself reaching for `Mocha.expects(...)` on anything else,
stop and add a seam instead.

### 0.5.3 Definition of done for any slice

A slice (e.g. "submit a task via the form") is done when **all** hold:

- [ ] One system test in `test/system/` drives the slice end-to-end and is green.
- [ ] Every new class has a focused unit test that covers its public messages.
- [ ] No class > 100 LoC, no method > 5 LoC (run `bin/rails stats`; eyeball outliers).
- [ ] No new `ENV[...]`, `Time.now`, `IO.popen`, or `system` call outside the
      designated seams in §0.5.2's table.
- [ ] `bin/rails test` and `bin/rails test:system` both green.
- [ ] One commit, message describes the user-visible behaviour
      ("submit task via form enqueues job"), not the mechanics.

---

## 1. Prerequisites (Windows)

### 1.1 Install Ruby

Use **RubyInstaller for Windows with DevKit** — simplest, no WSL needed.

```powershell
winget install RubyInstallerTeam.RubyWithDevKit.3.3
# new shell, then:
ridk install     # pick option 3 (MSYS2 + dev toolchain)
ruby -v          # expect ruby 3.3.x
gem -v
```

If `winget` is unavailable: download installer from rubyinstaller.org → run →
tick "Add to PATH" → run `ridk install`.

### 1.2 Install Rails 8 + Bundler

```powershell
gem install bundler --no-document
gem install rails -v "~> 8.0" --no-document
rails -v        # expect Rails 8.0.x
```

### 1.3 SQLite

RubyInstaller bundles sqlite3 native; the `sqlite3` gem will compile via DevKit.

### 1.4 Sanity check Claude CLI is callable from Ruby

```powershell
ruby -e "puts %x{claude --version}"
```

Must print a version. This is the same binary the runner will spawn.

---

## 2. Repo bootstrap

```powershell
cd C:\Users\Rafael Prado\Desktop\repos
rails new orchestrator-rails `
  --database=sqlite3 `
  --skip-test --skip-system-test `
  --skip-jbuilder --skip-action-mailbox --skip-action-mailer --skip-active-storage `
  --css=tailwind --javascript=importmap
cd orchestrator-rails
bin/rails db:create
bin/rails solid_queue:install   # adds solid_queue migration + config/queue.yml
bundle add mission_control-jobs
bundle add minitest-spec-rails  # we'll use Minitest spec syntax
bin/rails db:migrate
```

---

## 3. Domain model

Mirror the Python `Task` schema closely so the mental model survives.

### 3.1 Migration

```ruby
# db/migrate/.._create_claude_tasks.rb
create_table :claude_tasks, id: :string, limit: 12 do |t|   # short id like Python uses
  t.string  :status, null: false, default: "pending"        # pending|running|done|failed|cancelled
  t.string  :repo_path, null: false
  t.text    :prompt,    null: false
  t.string  :branch
  t.string  :model
  t.string  :docker_cmd
  t.integer :priority,  null: false, default: 0
  t.string  :log_path
  t.text    :error
  t.string  :solid_queue_job_id  # link to SQ row for retries/UI
  t.datetime :started_at
  t.datetime :finished_at
  t.timestamps
end
add_index :claude_tasks, :status
add_index :claude_tasks, [:status, :priority, :created_at]
```

Short id generated in `before_create` via `SecureRandom.hex(6)`.

### 3.2 Model

```ruby
class ClaudeTask < ApplicationRecord
  STATUSES = %w[pending running done failed cancelled].freeze
  validates :status, inclusion: { in: STATUSES }
  validates :repo_path, :prompt, presence: true

  scope :pending,  -> { where(status: "pending") }
  scope :running,  -> { where(status: "running") }
  scope :recent,   -> { order(created_at: :desc) }

  def enqueue!
    job = RunClaudeJob.set(priority: -priority).perform_later(id)
    update!(solid_queue_job_id: job.provider_job_id)
  end

  def log_text = log_path && File.exist?(log_path) ? File.read(log_path) : nil
end
```

---

## 4. The job — replaces `Dispatcher` + `flow.py` + `executor.py`

Solid Queue gives us:

- worker pool (concurrency in `config/queue.yml`)
- claim with `FOR UPDATE SKIP LOCKED` equivalent (SQLite uses busy_timeout + tx)
- retry/backoff via `retry_on … wait:`
- **per-`repo_path` lock** via `limits_concurrency_to`
- failed-job dashboard (Mission Control)
- cron via `recurring.yml`

### 4.1 Concurrency + repo lock

```yaml
# config/queue.yml
default: &default
  workers:
    - queues: claude
      threads: 4              # = ORCH_CONCURRENCY
      processes: 1
      polling_interval: 2
production:
  <<: *default
development:
  <<: *default
```

```ruby
# app/jobs/run_claude_job.rb
class RunClaudeJob < ApplicationJob
  queue_as :claude

  # One task per repo at a time — replaces Python's claim_next_pending exclusion.
  limits_concurrency to: 1, key: ->(task_id) { ClaudeTask.find(task_id).repo_path }

  # Cooldown after a usage-limit failure — replaces today's _cooldown_until.
  retry_on Claude::UsageLimitError, wait: 30.minutes, attempts: 5
  retry_on Claude::TimeoutError,    wait: 1.minute,  attempts: 2
  discard_on ActiveRecord::RecordNotFound

  def perform(task_id)
    ClaudeRunner.new(ClaudeTask.find(task_id)).call
  end
end
```

> `limits_concurrency` is built into Solid Queue 1.x — exactly your
> "two clones run, same path serialized" rule.

### 4.2 The runner — replaces `runner.py` + `executor.py`

```ruby
# app/services/claude_runner.rb
class ClaudeRunner
  LIMIT_PATTERNS = [
    /usage limit reached/i,
    /you've hit your limit/i,
    /5-hour limit reached/i
  ].freeze

  def initialize(task, command_builder: ClaudeCommand.new, clock: Time)
    @task, @builder, @clock = task, command_builder, clock
  end

  def call
    @task.update!(status: "running", started_at: @clock.current, log_path: log_file)
    File.open(log_file, "a") { |f| f.puts header }

    exit_status, limit_hit = stream_subprocess
    finalize(exit_status, limit_hit)
  end

  private

  def stream_subprocess
    argv = @builder.build(@task)
    limit_hit = nil
    status = nil
    Dir.chdir(@task.repo_path) do
      IO.popen(argv, err: %i[child out]) do |io|
        File.open(log_file, "a") do |log|
          io.each_line do |line|
            log.write(line); log.flush
            limit_hit ||= LIMIT_PATTERNS.find { |re| line.match?(re) }&.source
          end
        end
        status = $?.exitstatus      # set after block
      end
    end
    [status, limit_hit]
  end

  def finalize(exit_status, limit_hit)
    if limit_hit
      @task.update!(status: "failed", error: "claude usage limit hit: #{limit_hit}", finished_at: @clock.current)
      raise Claude::UsageLimitError, limit_hit       # triggers retry_on cooldown
    elsif exit_status.zero?
      @task.update!(status: "done", finished_at: @clock.current)
    else
      @task.update!(status: "failed", error: "exit code #{exit_status}", finished_at: @clock.current)
      raise Claude::ExitError, "exit #{exit_status}"
    end
  end

  def log_file = Rails.root.join("logs", "#{@task.id}.log").to_s
  def header   = "===== task #{@task.id} =====\ncwd: #{@task.repo_path}\nargv: #{@builder.build(@task).inspect}\n"
end
```

```ruby
# app/services/claude_command.rb     # mirrors orch/command.py
class ClaudeCommand
  def initialize(bin: ENV.fetch("ORCH_CLAUDE_BIN", "claude"),
                 flags: ENV.fetch("ORCH_CLAUDE_FLAGS", "-p --permission-mode acceptEdits").split,
                 model: ENV.fetch("ORCH_CLAUDE_MODEL", "sonnet"),
                 max_turns: ENV.fetch("ORCH_CLAUDE_MAX_TURNS", "30").to_i)
    @bin, @flags, @model, @max_turns = bin, flags, model, max_turns
  end

  def build(task)
    cmd = [@bin, *@flags, "--model", task.model || @model, "--max-turns", @max_turns.to_s, task.prompt]
    return cmd unless task.docker_cmd
    [*task.docker_cmd.split, cmd.shelljoin]
  end
end
```

### 4.3 Errors module

```ruby
module Claude
  class Error < StandardError; end
  class UsageLimitError < Error; end
  class TimeoutError    < Error; end
  class ExitError       < Error; end
end
```

---

## 5. UI

### 5.1 Mission Control (free)

```ruby
# config/routes.rb
mount MissionControl::Jobs::Engine, at: "/jobs"
```

→ `http://localhost:3000/jobs` shows queues, in-progress, failed
(with retry/discard), scheduled.

### 5.2 Custom Tasks page (minimal)

```ruby
# config/routes.rb
root "tasks#index"
resources :tasks, only: %i[index new create show] do
  member { post :retry; post :cancel }
end
```

```ruby
# app/controllers/tasks_controller.rb
class TasksController < ApplicationController
  def index   = @tasks = ClaudeTask.recent.limit(100)
  def show    = @task  = ClaudeTask.find(params[:id])
  def new     = @task  = ClaudeTask.new
  def create
    @task = ClaudeTask.new(task_params.merge(id: SecureRandom.hex(6)))
    if @task.save
      @task.enqueue!
      redirect_to @task, notice: "queued"
    else
      render :new, status: :unprocessable_entity
    end
  end

  def retry
    t = ClaudeTask.find(params[:id])
    t.update!(status: "pending", error: nil, finished_at: nil, started_at: nil)
    t.enqueue!
    redirect_to t
  end

  def cancel
    t = ClaudeTask.find(params[:id])
    t.update!(status: "cancelled") if t.status == "pending"
    redirect_to t
  end

  private
  def task_params = params.require(:claude_task).permit(:repo_path, :prompt, :branch, :model, :docker_cmd, :priority)
end
```

Three views — `index.html.erb` (table), `new.html.erb` (form),
`show.html.erb` (status, error, **"View log" link** that hits a
`/tasks/:id/log` action returning `log_text` as `text/plain`).
Tailwind styles. Total ~60 LoC of ERB.

---

## 6. Tests (Minitest)

**Read §0.5 first.** Tests are written outside-in: a failing system test in
`test/system/` drives every slice; unit tests below it exist only because
the e2e forced them into existence. The table below is the *final* shape,
not the order of writing.

| File | Replaces | Asserts |
|---|---|---|
| `test/services/claude_command_test.rb` | `test_command_builder.py` | argv assembly, docker mode |
| `test/services/claude_runner_test.rb` | `test_executor.py` + `test_limits.py` | success / non-zero exit / limit detection / log file written |
| `test/jobs/run_claude_job_test.rb` | `test_dispatcher.py` | `retry_on UsageLimitError`, `limits_concurrency` invariants |
| `test/models/claude_task_test.rb` | `test_repository.py` | scopes, validations |
| `test/system/tasks_flow_test.rb` | `test_cli_pipeline.py` | new → enqueue → fake runner runs → show page renders |

Stub the subprocess with a Ruby fake (`test/support/fake_claude.rb`) that
mirrors `tests/e2e/fake_claude.py` — argv-driven, zero network.

---

## 7. Parity checklist (must hold before cutover)

- [ ] Add task via web → row created, status `pending`, SQ job enqueued.
- [ ] Worker picks it up → status `running`, log file written under `logs/<id>.log`.
- [ ] Success → status `done`, finished_at set.
- [ ] Non-zero exit → status `failed`, `error="exit code N"`.
- [ ] Limit phrase in stdout → status `failed`, `error="claude usage limit hit: …"`,
      **and** SQ schedules retry in 30 min.
- [ ] Two tasks with same `repo_path` → only one runs at a time
      (verify via Mission Control "in progress").
- [ ] Two tasks with different `repo_path` → both run in parallel up to thread cap.
- [ ] Worker crash mid-task → on restart, SQ requeues claimed-but-orphaned
      executions automatically.
- [ ] `View log` shows the same content as `cat logs/<id>.log`.
- [ ] Mission Control: failed-jobs page shows the backtrace; "Retry" works.
- [ ] Docker mode: `docker_cmd` set → argv wraps the claude command correctly.

---

## 8. Cutover (big-bang)

1. Drain Python: `orch list --status pending` empty, dispatcher stopped.
2. Hand-migrate any rows you still care about (one-shot Ruby script reading the
   old `data/orch.sqlite`, inserting into the new DB).
3. Stop the Python `start-server.ps1` and `start-dispatcher.ps1`.
4. New PowerShell scripts in `orchestrator-rails/bin/`:
   - `bin/start-web.ps1` → `bin/rails server`
   - `bin/start-worker.ps1` → `bin/jobs start` (Solid Queue's worker entry)
5. Archive the Python repo (`git tag v-python-final && git push --tags`);
   delete `.venv`, `data/`, `logs/` once you trust the Rails one.

---

## 9. What you lose vs. what you gain

**Lose**

- Live streaming logs in the UI mid-run (your choice — "View log" link only).
- The `orch` CLI (your choice — web-only).
- Python codebase (big-bang).

**Gain**

- ~400–500 fewer lines of code.
- Proper failed-job dashboard with retry buttons.
- `retry_on … wait:` replaces hand-rolled cooldown loop.
- `limits_concurrency` replaces hand-rolled busy-repo exclusion.
- Cron-style recurring (if you ever want "rebuild every Monday").
- Real ORM with migrations, console (`bin/rails c`), generators.

---

## 10. Effort buckets (relative size, no time estimates)

| Bucket | Size | Notes |
|---|---|---|
| Toolchain install (§1) | XS | One-time Windows pain |
| Bootstrap + schema (§2–3) | S | Rails generators do most of it |
| Job + Runner + Command (§4) | **M** | Real logic: subprocess + limit detection + log writing |
| UI (§5) | S | 3 views + Mission Control mount |
| Tests (§6) | M | Mirror existing Python test cases |
| Parity verification (§7) | S | Manual checklist |
| Cutover (§8) | XS | Stop Python, start Rails |

Bucket M's are where bugs hide — the runner's subprocess streaming on Windows
(process handles, signals, `IO.popen` quirks vs. `asyncio.create_subprocess_exec`)
is the highest-risk piece.

---

## 11. Known risks / open questions

1. **Windows subprocess kill semantics** — `Process.kill("KILL", pid)` and SQ's
   `terminate-then-kill` will need verifying against `claude.exe`.
   Python's `proc.kill()` works; Ruby on Windows can be flakier.
   Mitigation: write an integration test that spawns a long-running fake and
   cancels via Mission Control.
2. **SQLite + Solid Queue under load** — fine for your concurrency=4. If you
   ever raise it past ~20, switch to Postgres. Not a today-problem.
3. **Mission Control auth** — ships unauthenticated. For a localhost-only tool
   that's fine; if you ever expose it, gate it with HTTP basic auth
   (`Rails.application.config.mission_control.jobs.http_basic_auth_user/password`).
4. **No live log tail** (your choice) — confirmed acceptable. If you change
   your mind later, `ActionCable` + `Turbo::StreamsChannel` + a tiny log
   tailer is ~30 LoC.
5. **Hand-migration of in-flight Python tasks** — only relevant if you have
   unfinished work. Otherwise skip §8.2.

---

## 12. Suggested execution order

This is the **outside-in slice order** described in §0.5.2. Each numbered
step is one feature slice = one failing system test → drop down → climb back
up → green → commit. Do not batch slices.

1. §1 install Ruby/Rails, sanity-check `claude.exe` callable.
2. §2 bootstrap repo, commit "skeleton".
3. §3 model + migration, commit "schema" (one model test for validations + scopes).
4. **Slice A — "submit a task via the form enqueues a job"**:
   write `test/system/submit_task_test.rb` first; it will force §5 controller
   + view + §3 `enqueue!`. Stub the `Subprocess` seam with `FakeClaude`.
   Drop into unit tests for `ClaudeCommand` and `ClaudeRunner` only when the
   system test demands them. Commit "slice A".
5. **Slice B — "runner streams output and marks task done"**:
   extend the system test (or add a sibling) to assert the show page reports
   `done` and the log file contains scripted output. This is what forces
   `ClaudeRunner` into existence; build the `Subprocess` role here.
   Commit "slice B".
6. **Slice C — "usage-limit phrase triggers retry"**: system test seeds
   `FakeClaude` to print a limit phrase; assert task is `failed` and Solid
   Queue has a scheduled retry. This forces §4.1's `retry_on`. Commit "slice C".
7. **Slice D — "two tasks on same repo serialize"**: system test or job test
   that enqueues two and asserts ordering via `limits_concurrency`. Commit "slice D".
8. **Slice E — "view log + Mission Control mount"**: system test clicks
   "View log" and asserts content. Commit "slice E".
9. §7 manual parity walkthrough against the now-green suite.
10. §8 cutover.

At every commit boundary, the checks in §0.5.3 must hold.
