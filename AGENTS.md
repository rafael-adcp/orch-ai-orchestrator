# AGENTS.md — house rules for AI agents

Read this file before doing **any** work on this repo. It applies to every
AI tool that touches the codebase: Claude Code (via `CLAUDE.md`), GitHub
Copilot (via `.github/copilot-instructions.md`), Cursor, Aider, Codex, etc.
If you change this file, also update those pointer files.

---

## 1. Hard limits (these override your defaults)

POODR-style discipline applies — but the only rules worth writing down are
the ones a generic "good code" instinct won't enforce:

- Classes ≤ 100 LOC. Methods ≤ 5 LOC. Methods take ≤ 4 arguments.
- One controller action ↔ one instance variable ↔ one view.
- Every external boundary (subprocess, clock, filesystem, network,
  third-party gem state) goes behind an injectable seam. Tests inject
  fakes; only the real seam touches the world. This is non-negotiable
  because the verify bar (§3) depends on it.

If a change can't fit these limits, the design is wrong — split before
you ship.

---

## 2. Workflow: analyse → plan → execute → verify

### Analyse

When reading the affected slice, actively look for:

1. **Two state machines pretending to be one.** The most common bug class
   in this repo. If a model field mirrors state owned by a framework
   (Solid Queue, ActionCable), assume the mirror is lying until proven
   otherwise.
2. **Reinventing the wheel.** Hand-rolled retry, locking, scheduling, or
   state — when the framework already provides it.

### Plan

For non-trivial work, surface a plan and start executing. The
plan names the smell, the minimal cohesive diff, and the test you'll
write *first* that would catch a regression of this bug. Trivial work
(rename, typo, obvious bug) — execute directly.

### Execute

- One logical change per commit. No "fix + drive-by refactor" commits.
- No backwards-compat shims for code that hasn't shipped.

---

## 3. Verify (the e2e bar)

A change is not done until:

1. **Unit tests** cover every changed behaviour, using injected fakes.
2. **Integration tests** walk the full slice (form → controller → job →
   service → DB → log) with only the outermost seam faked. They must
   execute *past step 1* — if the feature retries or schedules, the test
   runs `perform_enqueued_jobs` twice with `travel_to(future)`. The
   classic regression here was an integration test that asserted a retry
   was *enqueued* but never *ran* it, so the bug shipped.
3. **System tests** — UI flows via `bin/rails test:system` (rack_test).
4. **Lint** — `bin/rubocop` clean for files you touched. Leave
   pre-existing offences in untouched files alone.

Before declaring done:

```
bin/rails test
bin/rails test:system
bin/rubocop
```

Partial green is not green.

---

## 4. Specific lessons this repo paid for

Pattern-match against these — they are not derivable from reading code.

- **Two state machines lying to each other.** AiTask used to mirror Solid
  Queue's job state on its own `status` column. SQ retried; AiTask's
  transition table refused. Now: AiTask owns *outcomes*
  (`in_flight`, `done`, `failed`, `blocked`, `needs_review`, `cancelled`);
  Solid Queue owns *mechanics* (`queued`, `running`, `retrying`,
  `scheduled_at`, attempts). The `TaskStatus` presenter is the single
  point that combines them for the UI. **Never recreate this mirror.**

- **Cooldowns / timeouts / attempt counts live in exactly one place.** If
  the runner shows "next retry at X" and the job declares
  `retry_on … wait: 30.minutes`, both numbers come from the same source.
  Read SQ's `scheduled_at`; don't compute your own.

- **Logs append across attempts.** Don't truncate on retry. Use
  timestamped events (`LogWriter#event`) so a reader can tell attempt 1
  from attempt 2 from process stdout.

- **Cancel must clean up the queue.** If you mark a row "cancelled",
  also discard the queued job, or it will fire later and surprise everyone.

---

## 5. When in doubt

- Smallest change that fixes the named problem.
- Existing framework feature over a hand-rolled equivalent.
- One source of truth over two that "should stay in sync".
- Name an in-between state explicitly rather than overloading an existing one.
- Ask before destructive actions (force-push, drop column, delete branch,
  rewrite history).