# orchestrator-rails — Claude Code task queue

Persistent SQLite queue + **Solid Queue** worker pool + **Mission Control**
dashboard + a Rails web UI. Queue up tasks and it runs `claude -p` in
parallel (up to N at a time), optionally inside a Docker container for each
repo.

## Why

Hopping between terminals to feed Claude Code prompts one by one wastes time,
especially when you have a backlog of small-to-medium changes spread across
several repos. This app lets you dump every idea into a queue — _which repo,
which env, which prompt_ — and walks away. A pool of N threads (default 4)
keeps Claude busy in parallel, one task per dev env, no babysitting.

Drop a prompt in the form, close the laptop, come back to a list of finished
tasks with full logs.

**Built for:**

- Multiple Docker dev envs of the same project (`projeto-ABC-env-1`, `-env-2`, …)
  running in parallel without stepping on each other.
- Long-running, autonomous Claude Code runs (with `--max-turns` so the agent
  actually _does_ the work instead of asking for clarification).
- 100% local, zero external services — your prompts and code never leave your
  machine.
- Full transparency: every task is one Solid Queue job; failures land in
  Mission Control with backtraces and a one-click retry.

## How it works

```
   POST /tasks ──►  AiTask row (SQLite)
                       │
                       │ enqueue!
                       ▼
            ┌────────────────────────┐
            │  Solid Queue worker    │  ← bin/jobs (4 threads default)
            └──────────┬─────────────┘
                       │ limits_concurrency to: 1, key: repo_path
                       ▼
       ┌──────── RunClaudeJob ────────┐
       │  job #1 ──► claude -p (IO.popen)
       │  job #2 ──► claude -p
       │  job #3 ──► claude -p
       │  job #4 ──► claude -p
       └──────────────────────────────┘
                       │
                       ▼
        Mission Control at /jobs
        Tasks UI at /
        log/tasks/<task-id>.log on disk
```

Each task becomes a Solid Queue job. Watch progress / retry / discard from
Mission Control at `/jobs`. The runner also writes `log/tasks/<task-id>.log`
and updates the row's status in SQLite.

## Setup (Windows / PowerShell)

```powershell
cd C:\Users\Rafael Prado\Desktop\repos\orchestrator-rails

# Ruby 3.3.x is required. If `ruby -v` doesn't print 3.3, prepend the path:
$env:PATH = "C:\Ruby33-x64\bin;$env:PATH"

bundle install
ruby bin/rails db:prepare
```

## Setup (macOS / Linux)

```bash
cd ~/repos/orchestrator-rails

# Ruby 3.3.x via rbenv / asdf / mise
ruby -v   # expect 3.3.x

bundle install
bin/rails db:prepare
```

## Starting the 2 processes

In **two separate terminals** (or two tabs):

### Windows

```powershell
# Terminal 1 — web (Puma)
.\bin\start-web.ps1
```

```powershell
# Terminal 2 — Solid Queue worker pool (--mode async, see notes)
.\bin\start-worker.ps1
```

> **Windows note:** Solid Queue defaults to a forking supervisor, which is
> unimplemented on Windows. The script above passes `--mode async` so workers
> run as threads inside one process. Functionally identical for this app.

### macOS / Linux

```bash
# Terminal 1 — web (Puma)
bin/rails server
```

```bash
# Terminal 2 — Solid Queue worker pool
bin/jobs start
```

UI: <http://localhost:3000>
Dashboard: <http://localhost:3000/jobs>

## Adding tasks

Tasks are queued through the web form at `/tasks/new`. Required: `repo_path`
and `prompt`. Optional: `branch`, `model`, `docker_cmd`, `priority`.

```
http://localhost:3000/tasks/new
```

You can also enqueue from the Rails console:

```ruby
bin/rails console
> AiTask.create!(
    id:        SecureRandom.hex(6),
    repo_path: "C:/repos/project-x",
    prompt:    "implement /users endpoint with pagination and tests",
    priority:  1
  ).enqueue!
```

From the show page (`/tasks/:id`):

- **View log** — opens the streaming log file as plain text.
- **Retry** — resets a `failed`/`done` task to `pending` and re-enqueues it.
- **Cancel** — marks a `pending` task `cancelled` (no-op if already running).

## Configuration

Configured via environment variables (read by `ClaudeCommand`):

| Var | Default | Description |
|---|---|---|
| `ORCH_CLAUDE_BIN` | `claude` | Claude Code binary |
| `ORCH_CLAUDE_FLAGS` | `-p --permission-mode acceptEdits` | Default flags |
| `ORCH_CLAUDE_MODEL` | `sonnet` | Default model when task has none |
| `ORCH_CLAUDE_MAX_TURNS` | `30` | `--max-turns` value |

Worker threads / queues live in [config/queue.yml](config/queue.yml).

Per-task retry / cooldown is declared in
[app/jobs/run_claude_job.rb](app/jobs/run_claude_job.rb):

```ruby
retry_on Claude::UsageLimitError, wait: 30.minutes, attempts: 5
retry_on Claude::TimeoutError,    wait: 1.minute,  attempts: 2
limits_concurrency to: 1, key: ->(task_id) { AiTask.find(task_id).repo_path }
```

## How each task is executed

1. `POST /tasks` creates an `AiTask` (status `pending`) and calls
   `enqueue!`, which pushes a `RunClaudeJob` onto the `claude` queue.
2. A Solid Queue worker picks it up. `limits_concurrency` blocks if another
   job for the **same `repo_path`** is already running.
3. `ClaudeRunner` flips the task to `running`, opens
   `log/tasks/<id>.log`, writes a header.
4. `ClaudeCommand` builds the argv:
   - without docker: `claude -p <flags> --model <m> --max-turns <n> "<prompt>"`
   - with docker: `<docker_cmd> "<claude argv shellescape'd>"`
5. `Subprocess#run` streams stdout/stderr line-by-line into the log file
   while scanning for usage-limit phrases (regexes in `ClaudeRunner::LIMIT_PATTERNS`).
6. On clean exit → `status=done`. Non-zero exit → `failed` with `exit code N`.
   Limit phrase detected → `failed` with the phrase **and** raises
   `Claude::UsageLimitError` so Solid Queue schedules a retry in 30 min.

## Notes

- **Isolated branch per task**: the orchestrator does **not** create branches
  or commit. Leave that to the Claude prompt itself (e.g. "create branch
  feature/x, implement, commit").
- **Same `repo_path` cannot run in parallel**: `limits_concurrency` serializes
  jobs that share a `repo_path` key. For true parallelism, clone the repo
  into distinct paths (e.g. `C:\repos\project-ABC-env-1`, `-env-2`, ...)
  and submit separate tasks.
- **API key**: ensure `ANTHROPIC_API_KEY` is set in the worker's environment
  (or inside the Docker container, if using that path).
- **Worker crash**: Solid Queue automatically reclaims orphaned executions
  on restart — no manual `reap_stale` step like the Python version had.
- **Mission Control auth**: HTTP Basic auth is **disabled in development**
  via [config/initializers/mission_control_jobs.rb](config/initializers/mission_control_jobs.rb).
  In production, set `MISSION_CONTROL_USER` and `MISSION_CONTROL_PASSWORD`
  env vars to enable it.
- **Cross-platform**: tested on Windows (PowerShell, async-mode worker) and
  macOS/Linux (forking worker). The `Gem.win_platform?` initializer in
  [config/initializers/solid_queue_windows_signals.rb](config/initializers/solid_queue_windows_signals.rb)
  trims the supervisor's signal list to what Windows supports.

## Testing

The codebase follows Sandi Metz / POOD limits (classes ≤100 LOC,
methods ≤5 LOC) — see [PORT_PLAN.md](PORT_PLAN.md) §0.5 for the
methodology. Every external boundary (subprocess, clock) sits behind
an injectable seam.

```powershell
# Run the full unit + integration suite (40 tests, ~2.5s)
ruby bin/rails test

# Run the browser-style end-to-end suite (4 tests, rack_test driver)
ruby bin/rails test:system

# Just one layer
ruby bin/rails test test/services
ruby bin/rails test test/jobs
ruby bin/rails test test/controllers
ruby bin/rails test test/integration

# Lint
ruby bin/rubocop

# Security audit
ruby bin/brakeman
ruby bin/bundler-audit
```

Notable layout:

| File | Purpose |
|---|---|
| [test/services/claude_command_test.rb](test/services/claude_command_test.rb) | argv construction, docker mode |
| [test/services/claude_runner_test.rb](test/services/claude_runner_test.rb) | streaming, exit handling, limit detection |
| [test/jobs/run_claude_job_test.rb](test/jobs/run_claude_job_test.rb) | retry / discard / concurrency key |
| [test/models/ai_task_test.rb](test/models/ai_task_test.rb) | validations, scopes, id generation |
| [test/controllers/tasks_controller_test.rb](test/controllers/tasks_controller_test.rb) | 404s, strong-params, mass-assignment guards |
| [test/integration/submit_task_test.rb](test/integration/submit_task_test.rb) | form → POST → enqueue (Slice A) |
| [test/integration/runner_completes_task_test.rb](test/integration/runner_completes_task_test.rb) | job → done + log written (Slice B) |
| [test/integration/usage_limit_retry_test.rb](test/integration/usage_limit_retry_test.rb) | limit phrase → failed + retry (Slice C) |
| [test/integration/task_actions_test.rb](test/integration/task_actions_test.rb) | view log, retry, cancel, MC mount (Slices D+E) |
| [test/system/task_workflow_test.rb](test/system/task_workflow_test.rb) | browser-style E2E: submit, retry, cancel, view log |
| [test/support/fake_claude.rb](test/support/fake_claude.rb) | argv-driven test double for `Subprocess` |

## What changed vs the Python version

| | Python/Prefect | Rails/Solid Queue |
|---|---|---|
| App code | 981 LOC | **398 LOC** (-59%) |
| Test code | 1,026 LOC | **530 LOC** (-48%) |
| Job dispatch | hand-rolled asyncio loop (172 LOC) | `solid_queue` gem |
| Per-repo lock | manual SQL "skip if running" | `limits_concurrency` (1 line) |
| Retry on limit | pauses entire dispatcher 30min | per-task `retry_on` with backoff |
| Stale recovery | manual `reap_stale_running()` | automatic in Solid Queue |
| Dashboard | separate Prefect server | Mission Control mounted at `/jobs` |
| UI | static HTML command builder | server-rendered CRUD |
| CLI | `orch add/list/show/logs/retry/cancel` | dropped (web-only) |
| Live log tail | `orch logs -f <id>` | dropped (View log link only) |
