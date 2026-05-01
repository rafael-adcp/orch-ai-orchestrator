# <img src="images/icon.png" alt="" height="80" valign="middle"> Orchestrator (Orch)

> **TL;DR:** A self-hosted job queue that runs AI coding prompts in parallel against your local repos.

<p align="center">
  <img src="images/full_picture.png" alt="Orchestrator UI overview">
</p>



## Why?

Orchestrator (**Orch**) treats AI coding prompts the way a CI server treats builds: you push them onto a queue, a pool of workers picks them up, and a dashboard tells you what happened.

As developers we always have more we'd like to build than time to
build it. AI coding agents have made each individual change cheap
and fast — but every prompt still needs you in the driver's seat:
launching it, watching it, remembering which window had which task,
and being there when something goes wrong.

The bottleneck isn't the model (the car) anymore — it's the human
(the driver) in front of it. You can only watch so many spinners,
juggle so many windows, and stay awake for so many hours before
something gets dropped.

Orch removes you from the loop: queue the work, walk away, the workers do the rest.
- **Per-repo (repo_path) isolation.** Two prompts for the same repo never run at the same time, so working trees stay sane.
  - Want to do things in the same repository simultaneously? (aka real parallelism)
  clone the repo into distinct paths
  (`C:\repos\project-ABC-env-1`, `-env-2`, …) and submit one task per path.
- **Many prompts, many repos, in parallel.** Submit ten tasks across
  ten repos and Orch runs N at a time, never two on the same working
  tree simultaneously.
- **Work happens while you don't.** Queue a backlog before bed, on the
  commute, or before a meeting. Come back to finished branches instead
  of an empty editor.
- **Your prompt is what Claude sees.** Orch passes it through verbatim
  (plus the success sentinel footer), so anything you want done — a new
  branch, a commit, a push to remote, a PR — needs to be spelled out in
  the prompt itself.
- **Worker crashes are safe.** Solid Queue automatically reclaims
  orphaned executions once the dead worker's heartbeat goes stale
  (a few minutes by default) — no manual reaping required.
- **Usage limits don't kill the run.** When the provider throttles,
  the task is automatically rescheduled. No babysitting, no lost prompts.
- **Every task has a verdict.** Done, failed, blocked, needs-review —
  no "exit 0 but did nothing" surprises. (Details under the
  [success sentinel](#the-success-sentinel) below.)
- **Full audit trail.** Per-task append-only log on disk, plus retry
  history and backtraces in the built-in Mission Control dashboard.
- **Local-first.** Runs on your machine against your local clones; no
  hosted service, no extra infrastructure to operate.


## How it works (10,000 ft)

```
   POST /tasks ──►  AiTask row (SQLite)
                       │
                       │ enqueue!
                       ▼
            ┌────────────────────────┐
            │  Solid Queue worker    │  ← bin/jobs
            └──────────┬─────────────┘
                       │ limits_concurrency to: 1, key: repo_path
                       ▼
                  RunClaudeJob ──► claude -p (subprocess)
                       │
                       ▼
        Mission Control at /jobs
        Tasks UI at /
        log/tasks/<task-id>.log on disk
```

### Per-task pipeline

Each task is one Solid Queue job. The runner streams stdout/stderr
line-by-line into `log/tasks/<id>.log`, scans for usage-limit phrases
and the success/blocked sentinel, then stamps a terminal outcome on
the row.

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
      1. usage-limit phrase seen   →  raise UsageLimitError
                                      (SQ retries; task stays in_flight)
      2. non-zero exit code        →  failed ("exit code N")
      3. ORCH_RESULT: BLOCKED      →  blocked (with reason)
      4. ORCH_RESULT: SUCCESS      →  done
      5. exit 0, no sentinel       →  needs_review
```

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

## Requirements

- **Ruby 3.3.x**
- **[Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code)** on `PATH`, already authenticated (e.g. via `claude login`)
- SQLite — pulled in via the `sqlite3` gem; on some Linux distros you also need the system `libsqlite3` package

## Setup

No app-side config required — **Orch** just shells out to
the `claude` CLI, so whatever auth you already use with Claude Code
(e.g. `claude login`) keeps working.

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

## Adding tasks

Use the form at <http://localhost:3000/tasks/new>. Fields:

| Field | Required | Notes |
|---|---|---|
| `repo_path` | yes | Absolute path to the repo Claude should work in (`cwd` of the subprocess) |
| `prompt` | yes | What you want Claude to do. Orch passes it through verbatim, so anything you want done must be spelled out here. |
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

## Extending: other providers

> ⚠️ **Work in progress.** The seam exists but has only ever been
> exercised with the `claude` provider. Expect rough edges — interfaces
> may shift as a second provider is wired up.

The `ProviderRegistry` ([app/services/provider_registry.rb](app/services/provider_registry.rb))
maps a provider name to an `ActiveJob` class. Today only `claude` is
registered ([config/initializers/provider_registry.rb](config/initializers/provider_registry.rb))
but adding another agent CLI is essentially: write a new job + runner,
register it under a new name, and stick the right value in
`AiTask#provider`.

## Testing

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

## Stack

Rails 8.1 · Ruby 3.3 · SQLite · Solid Queue · Mission Control · Hotwire
(Turbo + Stimulus) · Tailwind CSS · Propshaft · Puma · Importmap.

## License

MIT — do whatever you want with it.
