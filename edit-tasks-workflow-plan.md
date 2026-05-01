# Edit Tasks Workflow — Design Plan

## Problem Statement

Once a task is created and enters a `queued` or `retrying` state, there is no way to
modify its parameters (prompt, repo_path, model, docker_cmd, priority). The only options
today are `cancel` (destroys it) or wait for it to run. This is painful when you spot a
typo in a prompt during a 30-minute retry cooldown.

---

## How Solid Queue fits in (the key insight)

`RunClaudeJob` receives **only `task_id`** at enqueue time. Every parameter (`prompt`,
`repo_path`, `model`, `docker_cmd`) is fetched fresh from the DB when the job actually
executes (`AiTask.find(task_id)` inside `ClaudeRunner`). This means:

- **Editing the DB row is sufficient** — the next execution will pick up the new values.
- We do **not** need to cancel-and-re-enqueue just to change a prompt.
- The only exception is `priority`, which is baked into the SQ job row at enqueue time
  via `.set(priority: -priority)`. Changing priority requires a discard + re-enqueue.

---

## Safe Edit Windows

| TaskStatus label | SQ job state     | Can edit safely? | Notes                                      |
|------------------|------------------|------------------|--------------------------------------------|
| `queued`         | ready, unclaimed | ✅ Yes           | Job hasn't started; DB write takes effect  |
| `retrying`       | scheduled        | ✅ Yes           | Job is sleeping; DB write takes effect     |
| `running`        | claimed          | ❌ No            | Job is mid-execution reading the same row  |
| Any terminal     | none             | ❌ No            | Use `retry` action instead                 |

Guard: `status.cancellable?` already returns `true` for queued/retrying and `false` for
running/terminal — reuse this predicate rather than re-implementing it.

---

## Two User Intents

When a user edits a waiting or retrying task, they likely have one of two goals:

1. **"Fix and let it run when it was going to anyway"** — just update the DB row; SQ
   fires at the already-scheduled time with the new params. Zero SQ disruption.

2. **"Fix and run it NOW"** — update the DB row, discard the waiting SQ job, and
   re-enqueue immediately. This also resets the retry counter (attempts back to 0),
   which is usually what the user wants after intentional changes.

The UI should offer both: a **Save** button (silent update) and a **Save & Retry Now**
button (update + immediate re-enqueue).

---

## Proposed Changes

### 1. Routes

```ruby
resources :tasks, only: %i[index new create show destroy] do
  member do
    get  :edit           # ← new
    patch :update        # ← new
    post :retry
    post :cancel
    get  :log
  end
end
```

### 2. `AiTask#editable?`

Add a predicate so the model owns the guard logic:

```ruby
def editable?
  status.cancellable?   # queued or retrying, not running or terminal
end
```

### 3. `AiTask#update_params!`

A thin service method that handles the two paths:

```ruby
def update_params!(attrs, requeue: false)
  return false unless editable?
  priority_changed = attrs[:priority] && attrs[:priority].to_i != priority

  update!(attrs.slice(:prompt, :repo_path, :model, :docker_cmd, :priority))

  if requeue || priority_changed
    status.discard_queued_job
    update!(outcome: IN_FLIGHT, error: nil, started_at: nil,
            finished_at: nil, active_job_id: nil)
    enqueue!
  end

  true
end
```

- Non-priority edits with `requeue: false` → pure DB write, SQ untouched.
- Any edit with `requeue: true` → discard + re-enqueue (same path as `retry!`).
- Priority changes always force a re-enqueue because the priority is baked into the SQ job.

### 4. `TasksController#edit` and `#update`

```ruby
def edit
  # @task set by before_action
end

def update
  requeue = params[:requeue] == "1"
  if @task.update_params!(task_params, requeue:)
    redirect_to @task, notice: requeue ? "Task updated and re-queued." : "Task updated."
  else
    render :edit, status: :unprocessable_entity
  end
end
```

Keep the controller thin — one instance variable, logic lives in the model.

### 5. View: `app/views/tasks/edit.html.erb`

Reuse the same fields partial as `new`. Add a conditional banner when the task is
currently retrying so the user understands the timing implications.

Two submit buttons:
- `name="requeue" value="0"` → Save (runs at the scheduled retry time)
- `name="requeue" value="1"` → Save & Run Now (discards cooldown, re-enqueues)

Show the **Save & Run Now** button only when `@task.status.label == :retrying`, because
for a purely queued task re-enqueuing has no practical difference.

### 6. Edit link on the index/show views

Conditionally show an "Edit" link when `task.editable?` — disabled/hidden for running
and terminal tasks.

---

## What We Deliberately Do NOT Do

- **No editing of running tasks.** The job is reading the same row mid-execution.
  Mutating it would be a race condition. The correct UX is: wait for it to finish,
  then edit-and-retry from the terminal state.
- **No partial re-enqueue** (changing only SQ metadata without a full discard + reenqueue).
  SQ doesn't support in-place mutation of a scheduled job's args or priority.
- **No `status` column mirror on AiTask.** The outcome field stays as-is; `TaskStatus`
  remains the single presenter that reconciles AiTask outcome + SQ state.

---

## Test Plan

### Unit tests (`test/models/ai_task_test.rb`)

- `editable?` returns true for queued/retrying, false for running and all terminals.
- `update_params!` with `requeue: false` updates DB fields and leaves `active_job_id`
  unchanged.
- `update_params!` with `requeue: true` discards the SQ job, resets outcome, and
  re-enqueues (assert new `active_job_id`).
- Priority change forces re-enqueue even when `requeue: false`.

### Integration tests (`test/integration/task_actions_test.rb`)

- Walk the full slice for the "save only" path:
  `PATCH /tasks/:id` → DB updated → SQ job still scheduled at original `scheduled_at`.
- Walk the full slice for the "save and retry now" path:
  `PATCH /tasks/:id?requeue=1` → DB updated → old job discarded → new job enqueued →
  `perform_enqueued_jobs` runs the job with the new prompt.

### Controller tests (`test/controllers/tasks_controller_test.rb`)

- `GET edit` on running task redirects (not editable).
- `PATCH update` on running task returns 422.
- `PATCH update` on queued task succeeds and redirects to show.

---

## Open Questions

1. **Audit trail**: Should we append a log event (via `LogWriter#event`) when a task is
   edited, so the log file shows "params updated at T"? Probably yes for observability.
2. **Partial edit while queued vs. terminal-then-retry**: Should we surface the edit
   button in the terminal state too, pre-populating the new-task form? Today "Copy link"
   does something similar. Probably out of scope for this ticket.
3. **Concurrency limit interaction**: If a re-enqueue is triggered but the concurrency
   limit (`limits_concurrency to: 1, key: repo_path`) blocks it, the SQ job sits in
   the blocked queue. This is existing behaviour and not new — document in code comments.
