# GitHub Copilot — house rules

The conventions for this repository live in [AGENTS.md](../AGENTS.md) at
the repo root. Read that file in full and apply its rules to every
suggestion, edit, and chat answer in this codebase.

Highlights you should never violate:

- Sandi Metz POODR limits: classes ≤ 100 LOC, methods ≤ 5 LOC, ≤ 4 args.
- One state machine per concept. Don't mirror framework state (Solid Queue,
  ActiveRecord, etc.) onto your own model column.
- Every external boundary (subprocess, clock, filesystem, queue) sits
  behind an injectable seam.
- A change isn't done until `bin/rails test`, `bin/rails test:system`, and
  `bin/rubocop` are all green for files you touched.
- Tests must walk past step 1 of multi-step flows (retries, schedules,
  lifecycles). If the feature has a "second attempt", the test runs it.

When in doubt, defer to AGENTS.md.
