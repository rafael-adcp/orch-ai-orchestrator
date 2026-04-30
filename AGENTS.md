# AGENTS.md — house rules for AI agents

Read this file before doing **any** work on this repo. It applies to every
AI tool that touches the codebase: Claude Code (via `CLAUDE.md`), GitHub
Copilot (via `.github/copilot-instructions.md`), Cursor, Aider, Codex, etc.
If you change this file, also update those pointer files so the rules don't
drift across tools.

---

## 1. Mindset: Sandi Metz POODR + Tell-Don't-Ask

Every change is judged against POODR's design discipline. Internalise the
rules; don't recite them.

**Class & method shape (hard limits, not suggestions):**

- Classes ≤ 100 LOC. If you cross this, you've conflated responsibilities.
- Methods ≤ 5 LOC. If you cross this, extract a helper or a collaborator.
- Methods take ≤ 4 arguments (use a struct/keyword args if you need more).
- One controller action ↔ one instance variable handed to one view.
- One view knows about one instance variable.

**Object design:**

- Tell, don't ask. If you find yourself reading a field and branching on
  it from outside, the behaviour belongs on the object that owns the field.
- Single Responsibility per class. If a sentence describing the class needs
  the word "and", split it.
- Depend on *abstractions* (a duck-typed interface), not concretions. Inject
  collaborators through the constructor; don't `new` them inside methods.
- Isolate every external boundary (subprocess, clock, filesystem, network,
  third-party gem state) behind an injectable seam. Tests get a fake; the
  real seam touches the world.
- Prefer composition over inheritance. Inheritance is for *is-a* with
  shared substance, not "I want to reuse three lines."

**Naming:**

- Names describe *what* (an `OutcomePresenter`), not *how* (`StatusManager`).
- A method named `do_thing` or `process` is a smell — name the actual job.
- Booleans end in `?`; mutators end in `!` only when they bypass a guard.

---

## 2. Workflow: analyse → plan → execute → verify

This is the workflow you follow when a user gives you a task. Skipping any
step is a regression.

### 2.1 Analyse

Before touching code, **read enough of the repo to form a mental model** of
the affected slice. Specifically:

1. Find the involved classes/services/jobs and their tests.
2. Identify each external seam in play (DB, queue, subprocess, clock).
3. Look for *two state machines pretending to be one* — that is the most
   common bug class in this repo's history. If a field on a model mirrors
   state owned by a framework (Solid Queue, ActionCable, etc.), assume the
   mirror is lying until proven otherwise.
4. Look for "reinventing the wheel" smells: hand-rolled retry, hand-rolled
   locking, hand-rolled scheduling, hand-rolled state — when the framework
   already provides it.

### 2.2 Plan

Produce a short plan **before making changes**. The plan must include:

- The smell or design flaw, named.
- The minimal change that fixes it. Not a refactor with a fix bolted on —
  the smallest cohesive diff that closes the gap.
- The seams you will touch and the ones you will *not* touch.
- The test you will write *first* that would catch a regression of this bug.
- A short list of follow-ups that are genuinely out of scope (so they don't
  bloat this change).

For non-trivial work, surface the plan to the user and get a "go" before
executing. For trivial work (rename, typo, obvious bug), execute directly.

### 2.3 Execute

- Edit existing files in preference to creating new ones.
- One logical change per commit. Don't combine "fix bug" + "refactor area".
- Don't add backwards-compatibility shims for code that hasn't shipped.
- Don't add error handling for impossible states. Validate at boundaries
  (user input, external APIs); trust internal code.
- No comments that restate what the code does. Comments only earn their
  keep when the *why* is non-obvious (a hidden invariant, a workaround for
  a specific bug, a constraint a future reader would otherwise miss).

### 2.4 Verify (the e2e expectation)

A change is not done until it has been verified end-to-end. The bar:

1. **Unit tests** — every behaviour you changed has a unit test. Use
   injected fakes for seams; don't hit the world.
2. **Integration tests** — every "slice" (form → controller → job →
   service → DB → log) has a test that exercises the real wiring with
   only the outermost seam (the subprocess or external API) faked.
   Integration tests must walk the *full* path, including the second/third
   step where state-machine bugs hide. If the bug was "step 2 of a retry",
   the test runs `perform_enqueued_jobs` twice with `travel_to(future)`.
3. **System tests** — UI flows go through `bin/rails test:system` (rack_test).
4. **Lint** — `bin/rubocop` clean for files you touched.
5. **No new offences** — if rubocop reports pre-existing offences in files
   you didn't touch, leave them; don't sneak unrelated cleanups into the diff.

Before declaring "done", run:

```
bin/rails test
bin/rails test:system
bin/rubocop
```

If any of the three fails, fix it. Don't mark complete on partial green.

---

## 3. Specific lessons this repo paid for

These are concrete failure modes we've already hit. Pattern-match against
them.

- **Two state machines lying to each other.** AiTask used to mirror Solid
  Queue's job state on its own `status` column. SQ retried; AiTask's own
  transition table refused. Now: AiTask owns *outcomes* only
  (`in_flight`, `done`, `failed`, `blocked`, `needs_review`, `cancelled`);
  Solid Queue owns *mechanics* (`queued`, `running`, `retrying`,
  `scheduled_at`, attempts). The `TaskStatus` presenter is the single
  point that combines them for the UI. **Never recreate this mirror.**

- **Cooldowns / timeouts / attempt counts must live in exactly one place.**
  If the runner shows "next retry at X" and the job declares
  `retry_on … wait: 30.minutes`, those numbers must come from the same
  source. Read SQ's `scheduled_at` instead of computing your own.

- **Logs append across attempts.** Don't truncate on retry. Use timestamped
  events (`LogWriter#event`) for runner-emitted lines so a reader can tell
  attempt 1 from attempt 2 from process stdout.

- **Test the *second* step.** When a feature has retry, scheduling, or any
  multi-step lifecycle, the test must execute past step 1. The classic
  regression here was an integration test that only performed the first
  attempt and asserted a retry was *enqueued* — it never *ran* the retry,
  so the bug shipped.

- **Cancel must clean up the queue too.** If you mark a row "cancelled",
  also discard the queued job, or it will fire later and surprise everyone.

---

## 4. When in doubt

- Prefer the smallest possible change that fixes the named problem.
- Prefer existing framework features over hand-rolled equivalents.
- Prefer one source of truth over two that "should stay in sync".
- Prefer naming an in-between state explicitly over overloading an
  existing one.
- Ask the user before doing anything destructive (force-push, drop column
  in a migration, delete a branch, rewrite history).
