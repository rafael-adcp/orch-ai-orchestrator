# <img src="images/icon.png" alt="" height="80" valign="middle"> Orchestrator (Orch)

> **Queue Claude Code prompts. Walk away. Come back to finished work.**

A self-hosted Rails app that turns Claude Code into a parallel batch worker.
Drop prompts into a web form — _which repo, which model, which Docker env_ —
and a pool of background workers runs `claude -p` against each one,
streaming logs to disk and surfacing failures in a built-in dashboard.

<p align="center">
  <img src="images/full_picture.png" alt="Orchestrator UI overview">
</p>

---

## Why?

Hopping between terminals to feed Claude Code prompts one by one wastes
hours when you have a backlog of small-to-medium changes spread across
several repos.

Orchestrator lets you:

- **Batch a day's worth of work in 60 seconds.** Type the prompt, pick a
  repo, hit submit. Repeat. Close the laptop.
- **Make your downtime productive.** Queue up a backlog before bed, on
  your commute, or before a meeting — Orch keeps grinding while you're
  away. Wake up to a list of finished PRs instead of an empty editor.
- **Run N tasks in parallel** without them stepping on each other —
  enforced per-repo serialization means each working tree only ever has
  one Claude attached to it.
- **Survive usage limits.** When Anthropic throttles, the task is
  rescheduled automatically (default: retry in 30 minutes, up to 5×).
  No babysitting, no lost prompts.
- **Trust the outcome.** Every task ends with an explicit
  `done` / `failed` / `blocked` / `needs_review` / `cancelled` outcome —
  no "exit 0 but did nothing" surprises (more on the sentinel trick below).
- **Audit everything.** Per-task append-only log on disk; full retry
  history and backtraces in Mission Control at `/jobs`.
- **Keep it boring.** ~400 LOC of app code. SQLite, Solid Queue,
  Tailwind, Hotwire. No Redis, no separate scheduler, no extra service
  to babysit.

### Built for

- **Multiple Docker dev envs of the same project**
  (`projeto-ABC-env-1`, `-env-2`, …) running in parallel without
  stepping on each other.
- **Long autonomous Claude runs** with `--max-turns` so the agent
  actually _does_ the work instead of pausing for clarification.
- **Solo devs and small teams** who want a personal task queue, not a
  SaaS subscription.

---

## How it works

```
   POST /tasks ──►  AiTask row (SQLite)
                       │
                       │ enqueue!
                       ▼
            ┌────────────────────────┐
            │  Solid Queue worker    │  ← bin/jobs (3 threads default)
            └──────────┬─────────────┘
                       │ limits_concurrency to: 1, key: repo_path
                       ▼
       ┌──────── RunClaudeJob ────────┐
       │  job #1 ──► claude -p (IO.popen)
       │  job #2 ──► claude -p
       │  job #3 ──► claude -p
       └──────────────────────────────┘
                       │
                       ▼
        Mission Control at /jobs
        Tasks UI at /
        log/tasks/<task-id>.log on disk
```

Each task is one Solid Queue job. The runner streams stdout/stderr
line-by-line into `log/tasks/<id>.log`, scans for usage-limit phrases
and the success/blocked sentinel, then stamps a terminal outcome on
the row.

### Two state machines, cleanly separated

A core design rule: **the `AiTask` row only owns _outcomes_** —
`in_flight`, `done`, `failed`, `cancelled`, `needs_review`, `blocked`.
**Solid Queue owns _mechanics_** — `queued`, `running`, `retrying`,
`scheduled_at`, attempts. The `TaskStatus` presenter is the single
place that combines them for the UI. Cooldowns and attempt counts live
in exactly one place — nothing in app code mirrors them.

### The success sentinel

Claude can exit 0 having done nothing. To avoid silently shipping
"green" tasks that never actually finished, every prompt is appended
with a footer asking Claude to print exactly one of:

```
ORCH_RESULT: SUCCESS
ORCH_RESULT: BLOCKED: <reason>
```

If neither sentinel appears, the task lands in `needs_review` instead
of `done`. Disable with `ORCH_SENTINEL=0` (not recommended).

---

## Requirements

- **Ruby 3.3.x**
- **[Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code)** on `PATH` (or set `ORCH_CLAUDE_BIN`)
- **`ANTHROPIC_API_KEY`** in the worker's environment (or inside your Docker container, if using one)
- SQLite (bundled with Rails — no separate install)

---

## Setup

### Windows / PowerShell

```powershell
# If `ruby -v` doesn't print 3.3, prepend the path:
$env:PATH = "C:\Ruby33-x64\bin;$env:PATH"

bundle install
ruby bin/rails db:prepare
```

### macOS / Linux

```bash
# Ruby 3.3.x via rbenv / asdf / mise
ruby -v   # expect 3.3.x

bundle install
bin/rails db:prepare
```

---

## Running

You need **two processes**: the web server and the Solid Queue worker.

### Windows

```powershell
# Terminal 1 — web (Puma)
.\bin\start-web.ps1
```

```powershell
# Terminal 2 — Solid Queue worker pool (--mode async, see notes)
.\bin\start-worker.ps1
```

> **Windows note:** Solid Queue defaults to a forking supervisor, which
> is unimplemented on Windows. The script above passes `--mode async` so
> workers run as threads inside one process. Functionally identical for
> this app.

### macOS / Linux

```bash
# Terminal 1 — web
bin/rails server

# Terminal 2 — Solid Queue worker pool
bin/jobs start
```

Then open:

- **Tasks UI** — <http://localhost:3000>
- **Mission Control** — <http://localhost:3000/jobs>

---

## Adding tasks

Use the form at <http://localhost:3000/tasks/new>. Fields:

| Field | Required | Notes |
|---|---|---|
| `repo_path` | yes | Absolute path to the repo Claude should work in (`cwd` of the subprocess) |
| `prompt` | yes | What you want Claude to do |
| `branch` | no | Free-form note (orchestrator does not switch branches — let Claude do it) |
| `model` | no | Overrides `ORCH_CLAUDE_MODEL` for this task |
| `docker_cmd` | no | Wrap Claude in a Docker invocation, e.g. `docker run --rm -v %cd%:/app img` |
| `priority` | no | Higher = sooner. Default `0` |

You can also queue from the Rails console:

```ruby
bin/rails console
> AiTask.create!(
    repo_path: "C:/repos/project-x",
    prompt:    "implement /users endpoint with pagination and tests",
    priority:  1
  ).enqueue!
```

From the show page (`/tasks/:id`):

- **View log** — opens the streaming log file as plain text.
- **Retry** — resets a finished task to `in_flight` and re-enqueues it.
- **Cancel** — marks a queued/retrying task `cancelled` and discards
  the queued job so it cannot fire later.
- **Delete** — removes the row and its log file (only when not running).

The index has a **"Purge older than 30 days"** button that bulk-deletes
finished tasks and their logs. The same purge runs hourly in the
background ([config/recurring.yml](config/recurring.yml)).

---

## Configuration

All settings come from environment variables:

| Var | Default | Description |
|---|---|---|
| `ORCH_CLAUDE_BIN` | `claude` | Claude Code binary (resolved against `PATH`/`PATHEXT`) |
| `ORCH_CLAUDE_FLAGS` | `-p --permission-mode acceptEdits` | Default flags |
| `ORCH_CLAUDE_MODEL` | `sonnet` | Default model when task has none |
| `ORCH_CLAUDE_MAX_TURNS` | `30` | `--max-turns` value |
| `ORCH_SENTINEL` | `1` | Set `0` to skip the success-sentinel footer |
| `ANTHROPIC_API_KEY` | — | Required by the Claude CLI |
| `JOB_CONCURRENCY` | `1` | Number of worker processes (each runs 3 threads) |
| `MISSION_CONTROL_USER` / `MISSION_CONTROL_PASSWORD` | — | Enables HTTP Basic auth on `/jobs` in production |

Worker threads / queues live in [config/queue.yml](config/queue.yml).
Per-task retry / cooldown is declared in
[app/jobs/run_claude_job.rb](app/jobs/run_claude_job.rb):

```ruby
retry_on Claude::UsageLimitError, wait: 30.minutes, attempts: 5
limits_concurrency to: 1, key: ->(task_id) { AiTask.find(task_id).repo_path }
```

---

## How each task is executed

```
  POST /tasks
      │
      ▼
  AiTask row created (outcome = in_flight)
      │  enqueue!
      ▼
  Solid Queue worker picks up RunClaudeJob
      │  limits_concurrency blocks if another job
      │  for the same repo_path is already running
      ▼
  ClaudeRunner opens log/tasks/<id>.log
      │  builds argv via ClaudeCommand:
      │    • no docker:  claude -p <flags> --model <m> --max-turns <n> "<prompt+sentinel>"
      │    • w/ docker:  <docker_cmd> "<claude argv shellescaped>"
      ▼
  Subprocess#run streams stdout/stderr line-by-line
      │  → LogWriter        appends to log file
      │  → LimitDetector    scans for usage-limit phrases
      │  → SuccessDetector  scans for ORCH_RESULT sentinel
      ▼
  Outcome decision (first match wins)
  ┌─────────────────────────────────────┬─────────────────────────────────┐
  │ 1. usage-limit phrase seen          │ raise UsageLimitError       │
  │                                     │ → SQ retries; in_flight     │
  │ 2. non-zero exit code               │ failed ("exit code N")      │
  │ 3. ORCH_RESULT: BLOCKED             │ blocked (with reason)       │
  │ 4. ORCH_RESULT: SUCCESS             │ done                        │
  │ 5. exit 0, no sentinel              │ needs_review                │
  └─────────────────────────────────────┴─────────────────────────────────┘
```

---

## Tips

- **Per-repo serialization is by `repo_path`.** For real parallelism,
  clone the repo into distinct paths
  (`C:\repos\project-ABC-env-1`, `-env-2`, …) and submit one task per path.
- **The orchestrator does not branch or commit.** Tell Claude to do it
  in the prompt itself: _"create branch feature/x, implement, commit, push"_.
- **Worker crashes are safe.** Solid Queue automatically reclaims
  orphaned executions on restart — no manual reaping required.
- **Mission Control auth is off in development.** It's on in production
  if you set `MISSION_CONTROL_USER` and `MISSION_CONTROL_PASSWORD`.
  See [config/initializers/mission_control_jobs.rb](config/initializers/mission_control_jobs.rb).

---

## Extending: other providers

The `ProviderRegistry` ([app/services/provider_registry.rb](app/services/provider_registry.rb))
maps a provider name to an `ActiveJob` class. Today only `claude` is
registered ([config/initializers/provider_registry.rb](config/initializers/provider_registry.rb))
but adding another agent CLI is essentially: write a new job + runner,
register it under a new name, and stick the right value in
`AiTask#provider`.

---

## Testing

The codebase follows POODR-style discipline (classes ≤ 100 LOC, methods
≤ 5 LOC) — see [AGENTS.md](AGENTS.md) for the full house rules. Every
external boundary (subprocess, clock, filesystem) sits behind an
injectable seam so tests can fake it.

```powershell
# Full unit + integration suite
ruby bin/rails test

# Browser-style end-to-end (rack_test)
ruby bin/rails test:system

# One layer at a time
ruby bin/rails test test/services
ruby bin/rails test test/jobs
ruby bin/rails test test/controllers
ruby bin/rails test test/integration

# Lint
ruby bin/rubocop

# Security
ruby bin/brakeman
ruby bin/bundler-audit
```

---

## Stack

Rails 8.1 · Ruby 3.3 · SQLite · Solid Queue · Mission Control · Hotwire
(Turbo + Stimulus) · Tailwind CSS · Propshaft · Puma · Importmap.

## License

MIT — do whatever you want with it.
