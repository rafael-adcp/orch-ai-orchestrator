# Coverage sweep — from 74% (Codecov) to 100% (line + branch)

## Why we're at 74%

**Two distinct problems, one number.**

### 1. Codecov reporting bug (~22pp of the gap)

CI runs `bin/rails test` then `bin/rails test:system`. Both invocations
use SimpleCov's default `command_name`, so the second run **overwrites**
the resultset on disk instead of merging. Codecov uploads only the
system-test slice (~75%). Locally `bin/rails test` alone hits 97.39%
line / 89.62% branch.

**Fix:** set `SimpleCov.command_name` per suite. SimpleCov merges
resultsets keyed by command name automatically.

### 2. Real coverage gaps (10 lines, 11 branches)

Audited each gap. Three categories: by-design seams, dead/unreachable
code, and missing tests.

## Gap-by-gap plan

### A. Filter the boundary (6 lines)

| File | Lines | Action |
|---|---|---|
| `app/services/subprocess.rb` | 12–19 | `add_filter` in SimpleCov config. AGENTS.md §1: external boundaries are seams; tests inject fakes; only the real seam touches the world. By design. |

### B. Delete dead code (1 line, 0 branches)

| File | Line | Action |
|---|---|---|
| `app/services/provider_registry.rb` | L18 (`def known`) | Method has zero callers. Delete. |

### C. Simplify unreachable branches (0 lines, 2 branches)

| File | Branch | Action |
|---|---|---|
| `app/services/task_purge.rb` | `else skipped += 1` in `sweep` | Sweep query already excludes `IN_FLIGHT`; `delete()` only refuses for running in-flight rows; else branch is unreachable. Drop the ternary, the `skipped` counter, and the `skipped_count` field on `SweepReport`. |
| `app/services/task_status.rb` | `&.scheduled_at` in `next_retry_at` | Method runs `if retrying?`, which requires `sq_job` non-nil. Drop `&.` to plain `.` — the safe-nav is defensive but unreachable. |

### D. Add focused tests (3 lines, 9 branches)

| File | What to test |
|---|---|
| `app/services/log_writer.rb` L21 | `ensure_dir` rescue path: stub `FileUtils.mkdir_p` to raise `SystemCallError`, expect `WriteError`. |
| `app/services/limit_detector.rb` L35 + 3 branches | (a) reset string with unknown timezone; (b) malformed time portion; (c) raise inside `parse_reset_at` body. |
| `app/controllers/tasks_controller.rb` L43 + 1 branch | DELETE on a task whose `TaskPurge.delete` returns `deleted: false` (e.g. running). Expect redirect to `task_path` with alert flash. |
| `app/services/claude_runner.rb` 2 branches | (a) `mark_failed_safely` when task already terminal; (b) `log_event` when `log_path` is nil. |
| `app/services/task_status.rb` 2 `&.` branches | (a) `attempts` when `sq_job.arguments` is nil (returns 1); (b) `discard_queued_job` when `sq_job` is nil (no-op). |
| `app/services/claude_command.rb` 1 branch | Empty-PATH-entry guard inside `resolve_bin`. Either test (set PATH with `;;`) or wrap in `# :nocov:` — Windows-only platform code. |

## Execution order (one logical change per commit)

1. Wire SimpleCov merging (command_name per suite) and filter `Subprocess`.
2. Delete dead `ProviderRegistry.known`.
3. Simplify `TaskPurge#sweep` (drop unreachable else + `skipped_count`).
4. Simplify `TaskStatus#next_retry_at` (drop unreachable `&.`).
5. Add tests for `LogWriter` rescue.
6. Add tests for `LimitDetector` malformed inputs.
7. Add test for `TasksController#destroy` refused path.
8. Add tests for `ClaudeRunner` guards.
9. Add tests for `TaskStatus` `&.` branches.
10. Cover or `:nocov:` the `ClaudeCommand#resolve_bin` empty-PATH branch.

## Verify bar (per AGENTS.md §3)

After each commit, before declaring done on the PR:

```
bin/rails test
bin/rails test:system
bin/rubocop
```

Final coverage report should show **100% line, 100% branch** on the
merged resultset.
