# POODR Optimization Plan — Orchestrator Rails

> Sandi Metz discipline applied to this codebase.  
> Analysis date: 2026-05-01  
> Rules enforced: classes ≤ 100 LOC · methods ≤ 5 LOC · ≤ 4 args · injectable seams · Tell Don't Ask · Law of Demeter

---

## Priority Matrix

| # | Severity | File | Issue | Category |
|---|----------|------|-------|----------|
| 1 | **HIGH** | `app/services/claude_runner.rb:11-16` | 6 constructor parameters | Arg count |
| 2 | **HIGH** | `app/services/claude_runner.rb:7-9` | `subprocess_override` class-level mutable seam | Global state |
| 3 | **HIGH** | `app/services/task_status.rb:15-22` | Reconciles two state machines in one method | Implicit SM |
| 4 | **HIGH** | `app/controllers/tasks_controller.rb:50` | `TaskPurge.sweep` blocks HTTP request | Sync I/O |
| 5 | **HIGH** | `app/services/claude_command.rb:20-24` | 5 `ENV.fetch` calls at instantiation | Hardcoded env |
| 6 | **HIGH** | `config/orchestrator.yml` | Only 1 config value; 10+ hardcoded elsewhere | Config |
| 7 | **HIGH** | `app/jobs/purge_old_tasks_job.rb:8-10` | `older_than` accepts Duration OR Time | Type confusion |
| 8 | **HIGH** | `app/services/task_purge.rb:43` | `task.status.discard_queued_job` — Demeter/TDA | Tell Don't Ask |
| 9 | **MEDIUM** | `app/services/claude_runner.rb:21-34` | `call` method ~35+ LOC | Method length |
| 10 | **MEDIUM** | `app/services/limit_detector.rb:31,33-35` | Hardcoded `ActiveSupport::TimeZone` + broad rescue | Injectable seam |
| 11 | **MEDIUM** | `app/services/claude_command.rb:43-59` | 17-line Windows path resolution in command builder | SRP |
| 12 | **MEDIUM** | `app/services/log_writer.rb:10` | `Rails.root.join("log","tasks")` hardcoded default | Hardcoded path |
| 13 | **MEDIUM** | `test/integration/task_actions_test.rb:37-56` | Retry test enqueues job but never runs it | Test gap |
| 14 | **MEDIUM** | `app/views/tasks/show.html.erb:1` | View calls `TaskPurge.default_age` directly | View coupling |
| 15 | **LOW** | `app/models/ai_task.rb:50-51,83` | Manual `@status = nil` cache invalidation | Stale cache |
| 16 | **LOW** | `app/controllers/tasks_controller.rb:2` | `PER_PAGE = 100` not in config | Hardcoded const |
| 17 | **LOW** | `app/controllers/application_controller.rb:10` | `:tz` cookie key hardcoded | Hardcoded const |

---

## Fix 1 — Collapse ClaudeRunner's 6 constructor params into a `RunnerConfig` value object

**Problem** (`claude_runner.rb:11-16`):  
6 named parameters exceed the ≤4 rule and force every test that wants to fake one dependency to also specify the other five.

**Current:**
```ruby
def initialize(task,
               subprocess: ...,
               command_builder: ClaudeCommand.new,
               log_writer: LogWriter.new,
               limit_detector: LimitDetector.new,
               success_detector: SuccessDetector.new,
               clock: Time)
```

**Target:**
```ruby
# app/services/runner_config.rb
RunnerConfig = Struct.new(
  :subprocess, :command_builder, :log_writer,
  :limit_detector, :success_detector, :clock,
  keyword_init: true
) do
  def self.default
    new(
      subprocess:       Subprocess.new,
      command_builder:  ClaudeCommand.new,
      log_writer:       LogWriter.new,
      limit_detector:   LimitDetector.new,
      success_detector: SuccessDetector.new,
      clock:            Time
    )
  end
end

# app/services/claude_runner.rb
def initialize(task, config: RunnerConfig.default)
  @task   = task
  @config = config
end
```

**Tests:** Any test that fakes only `subprocess` passes `RunnerConfig.default.merge(subprocess: fake)`.  
**Why it matters:** Satisfies ≤4 args; each test only declares the seam it actually cares about.

---

## Fix 2 — Remove `subprocess_override` class-level test seam

**Problem** (`claude_runner.rb:7-9`):  
`ClaudeRunner.subprocess_override = ...` is global mutable state. Tests that forget teardown corrupt other tests; the production path depends on whether someone set a global.

**Target:** Delete the class accessor entirely. `RunnerConfig` (Fix 1) is now the seam. Tests build a `RunnerConfig` with the fake subprocess and pass it in; they never touch a class-level variable.

```ruby
# Before (in tests)
ClaudeRunner.subprocess_override = FakeSubprocess.new(...)
# teardown: ClaudeRunner.subprocess_override = nil

# After (in tests)
config = RunnerConfig.default.merge(subprocess: FakeSubprocess.new(...))
ClaudeRunner.new(task, config: config).call
```

**Why it matters:** Eliminates shared mutable state between test cases; no hidden ordering dependency.

---

## Fix 3 — Split the two state machines in `TaskStatus#label`

**Problem** (`task_status.rb:15-22`):  
`label` combines AiTask outcome transitions with Solid Queue job states in one method. This is the exact "two state machines pretending to be one" smell documented in AGENTS.md.

**Current:**
```ruby
def label
  return @task.outcome.to_sym unless @task.in_flight?
  return QUEUED unless sq_job
  return RUNNING  if sq_job.claimed?
  return RETRYING if retry_pending?
  return FAILED   if sq_job.failed?
  QUEUED
end
```

**Target:** Extract SQ reasoning into a private `SqJobLabel` calculator:

```ruby
# private inner calculator (or separate file if it grows)
class SqJobLabel
  def initialize(sq_job) = @sq_job = sq_job
  def call
    return :running  if @sq_job.claimed?
    return :retrying if retry_pending?
    return :failed   if @sq_job.failed?
    :queued
  end
  private
  def retry_pending? = @sq_job.scheduled_at&.future? && @sq_job.executions.to_i > 0
end

# task_status.rb
def label
  return @task.outcome.to_sym unless @task.in_flight?
  return :queued unless sq_job
  SqJobLabel.new(sq_job).call
end
```

**Why it matters:** Each class owns one machine; naming the boundary makes the AGENTS.md lesson legible in the code itself.

---

## Fix 4 — Move `TaskPurge.sweep` out of the request cycle

**Problem** (`tasks_controller.rb:50`):  
`TaskPurge.sweep` runs synchronously on every index/show request, blocking the HTTP thread for as long as the purge takes.

**Target:**
```ruby
# tasks_controller.rb — replace line 50
PurgeOldTasksJob.perform_later
```

Also pass purge age from the controller so the view doesn't reach into a service:

```ruby
# tasks_controller.rb
def show
  @task      = AiTask.find(params[:id])
  @purge_age = TaskPurge.default_age
end

# app/views/tasks/show.html.erb — replace line 1
<%# @purge_age already set by controller %>
```

**Why it matters:** Request latency is unaffected by database sweep size; controller responsibility narrows.

---

## Fix 5 — Read all ENV config at boot, not at instantiation

**Problem** (`claude_command.rb:20-24`):  
5 `ENV.fetch` calls inside `initialize` mean every test that constructs a `ClaudeCommand` must set ENV, and production has no validation at boot time.

**Target:** Read once in `config/initializers/orchestrator.rb` and expose via `Rails.application.config.orchestrator`:

```ruby
# config/initializers/orchestrator.rb
cfg = Rails.application.config.orchestrator
cfg[:claude_bin]       = ENV.fetch("ORCH_CLAUDE_BIN",   "claude")
cfg[:claude_flags]     = ENV.fetch("ORCH_CLAUDE_FLAGS",  "-p --permission-mode acceptEdits").split
cfg[:claude_model]     = ENV["ORCH_CLAUDE_MODEL"].presence || ClaudeCommand::DEFAULT_MODEL
cfg[:claude_max_turns] = ENV.fetch("ORCH_CLAUDE_MAX_TURNS", "30").to_i
cfg[:sentinel]         = ENV.fetch("ORCH_SENTINEL", "1") != "0"

# Validate eagerly so a missing required var blows up at boot, not mid-request
raise "ORCH_CLAUDE_BIN must be set in production" if Rails.env.production? && cfg[:claude_bin].blank?
```

```ruby
# claude_command.rb — constructor uses config, not ENV
def initialize(
  bin:       Rails.application.config.orchestrator[:claude_bin],
  flags:     Rails.application.config.orchestrator[:claude_flags],
  model:     Rails.application.config.orchestrator[:claude_model],
  max_turns: Rails.application.config.orchestrator[:claude_max_turns],
  sentinel:  Rails.application.config.orchestrator[:sentinel]
)
```

Tests override `Rails.application.config.orchestrator` in setup; no ENV mutation needed.

---

## Fix 6 — Consolidate all hardcoded constants into `orchestrator.yml`

**Problem**: Configuration is scattered — `PER_PAGE = 100` in the controller, `MAX_LIMIT_RETRIES = 5` in the job, `"UTC"` in ApplicationController, `"log/tasks"` in LogWriter.

**Target (`config/orchestrator.yml`):**
```yaml
default: &default
  purge_after_hours:   5
  tasks_per_page:      100
  max_limit_retries:   5
  default_timezone:    "UTC"
  timezone_cookie:     "tz"
  task_log_root:       "log/tasks"

development:
  <<: *default

test:
  <<: *default
  purge_after_hours: 1

production:
  <<: *default
```

Each hardcoded constant is then replaced by:
```ruby
Rails.application.config.orchestrator[:key_name]
```

---

## Fix 7 — Normalize `older_than` to always be a `Time`

**Problem** (`purge_old_tasks_job.rb:8-10`):  
The method inspects the type of `older_than` to decide whether to call `.ago`. This is a classic Duck Type violation — the caller decides, not the receiver.

**Current:**
```ruby
def perform(older_than: TaskPurge.default_age.ago)
  cutoff = older_than.is_a?(ActiveSupport::Duration) ? older_than.ago : older_than
end
```

**Target:** Always receive a `Time`; move `.ago` to all call sites:
```ruby
def perform(cutoff: TaskPurge.default_age.ago)
  TaskPurge.sweep(older_than: cutoff)
end
```

Any caller that currently passes a Duration calls `.ago` before enqueuing. The method body is now a single dispatch — no type inspection.

---

## Fix 8 — Tell Don't Ask in `TaskPurge#discard_queued_job`

**Problem** (`task_purge.rb:43`):  
`task.status.discard_queued_job` navigates through the presenter to trigger an action. Law of Demeter: tell the task, don't ask its presenter.

**Target:** Add `AiTask#cancel_queue!` that owns both the outcome write and the SQ discard:

```ruby
# app/models/ai_task.rb
def cancel_queue!
  return unless in_flight?
  status.discard_queued_job   # delegate stays one hop, not two
  transition_to_terminal!("cancelled")
end
```

```ruby
# app/services/task_purge.rb
def discard_queued_job(task)
  task.cancel_queue!
end
```

**Why it matters:** If the SQ discard logic moves (e.g., to a callback), `TaskPurge` doesn't change.

---

## Fix 9 — Break up `ClaudeRunner#call`

**Problem** (`claude_runner.rb`): `call` mixes orchestration, error rescue for three distinct error types, logging, and state transitions.

**Target:** Extract each rescue branch to a named method:

```ruby
def call
  run_subprocess
rescue LimitDetector::LimitReached => e  then handle_limit(e)
rescue ClaudeRunner::Cancelled            then handle_cancel
rescue => e                               then handle_error(e)
end

private

def run_subprocess     = ... # subprocess + log loop only, ≤ 5 LOC
def handle_limit(err)  = ... # limit-specific state + log, ≤ 5 LOC
def handle_cancel      = ... # cancel-specific cleanup, ≤ 5 LOC
def handle_error(err)  = ... # generic failure, ≤ 5 LOC
```

Each method is a single responsibility; the main `call` reads like a table of contents.

---

## Fix 10 — Make `LimitDetector` timezone-injectable and fail loudly

**Problem** (`limit_detector.rb:31,33-35`):  
`ActiveSupport::TimeZone` is called directly; parse failures are swallowed with `rescue nil`.

**Target:**
```ruby
def initialize(patterns: DEFAULT_PATTERNS, clock: Time,
               tz_resolver: ->(name) { ActiveSupport::TimeZone[name] })
  @tz_resolver = tz_resolver
end

def parse_reset_at(text)
  tz = @tz_resolver.call(m[2])
  raise ParseError, "unknown timezone: #{m[2]}" unless tz
  # ... rest of parsing
rescue ParseError
  nil   # explicit, documented
end
```

Tests inject a fake `tz_resolver`; the production seam is still the same one-liner.

---

## Fix 11 — Extract `ClaudeCommand#resolve_bin` to `CommandResolver`

**Problem** (`claude_command.rb:43-59`): 17 lines of platform-specific path resolution live inside the command builder, violating SRP.

**Target:**
```ruby
# app/services/command_resolver.rb
class CommandResolver
  def initialize(platform: RUBY_PLATFORM) = @platform = platform
  def call(bin) = windows? ? resolve_windows(bin) : bin
  private
  def windows? = @platform.match?(/mingw|mswin|cygwin/i)
  def resolve_windows(bin) = ... # same logic, isolated
end

# claude_command.rb
def initialize(..., resolver: CommandResolver.new)
  @bin = resolver.call(bin)
end
```

---

## Fix 12 — Log root should come from config, not a default parameter

**Problem** (`log_writer.rb:10`): `Rails.root.join("log", "tasks")` is a default parameter, so it's evaluated at class load time in some environments and can't be overridden without touching source.

**Target:**
```ruby
def initialize(root: Rails.application.config.orchestrator[:task_log_root],
               clock: Time)
  @root  = Rails.root.join(root)
  @clock = clock
end
```

Pairs with Fix 6 (add `task_log_root` to `orchestrator.yml`).

---

## Fix 13 — Retry integration test must run the job, not just enqueue it

**Problem** (`test/integration/task_actions_test.rb:37-56`): The test asserts the retry job is enqueued but never calls `perform_enqueued_jobs` a second time. Per AGENTS.md §3 point 2, integration tests must run past the enqueue step.

**Target:**
```ruby
def test_retry_resets_failed_task_and_runs
  # ... setup, first perform_enqueued_jobs ...
  post retry_task_path(task)
  perform_enqueued_jobs          # enqueue the retry job AND run it
  task.reload
  assert_equal "done", task.outcome   # verify the full slice, not just enqueue
end
```

Add a parallel test for the blocked/limit-retry path using `travel_to(future)`.

---

## Fix 14 — View-service coupling: pass `@purge_age` from controller

Covered in Fix 4. The controller sets `@purge_age`; the view reads `@purge_age`. `TaskPurge` is never referenced in a template.

---

## Fix 15 — Replace manual `@status = nil` with `def status(reload: false)`

**Problem** (`ai_task.rb:50-51,83`): Cache is cleared by setting `@status = nil` in two transition methods. Any new transition method that forgets this line silently uses stale state.

**Target:**
```ruby
def status(reload: false)
  @status = nil if reload
  @status ||= TaskStatus.new(self)
end

def retry!
  # ... logic ...
  status(reload: true)
end
```

Callers that need fresh state call `task.status(reload: true)` explicitly; the default is still memoized.

---

## Summary: Work Order

Work these in order — each fix reduces the diff noise for the next one.

1. **Fix 6** — Consolidate `orchestrator.yml` (no behavior change; sets up config foundation)
2. **Fix 5** — ENV to initializer (uses new config keys)
3. **Fix 1 + 2** — `RunnerConfig` + remove `subprocess_override` (structural, enables Fix 9)
4. **Fix 7** — Normalize `older_than` (safe, isolated)
5. **Fix 8** — Tell Don't Ask in TaskPurge (safe, isolated)
6. **Fix 4 + 14** — Async purge + controller passes `@purge_age` (behavior change — test first)
7. **Fix 3** — Split state machines in `TaskStatus` (write tests first)
8. **Fix 9** — Break up `ClaudeRunner#call` (refactor only — no test changes needed)
9. **Fix 11 + 12** — Extract `CommandResolver`, config-driven log root
10. **Fix 10** — `LimitDetector` timezone injection
11. **Fix 13** — Fix retry integration test
12. **Fix 15** — `status(reload:)` pattern
13. **Fix 16 + 17** — Remaining low-priority constants

Each fix must pass `bin/rails test && bin/rails test:system && bin/rubocop` before moving to the next.
