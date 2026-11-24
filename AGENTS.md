# Draft for future `AGENTS.md` — SysGuard Agent Safety Rules

> **PROPOSAL ONLY; NOT YET IN REPOSITORY.** Team must review before copying to WSL. This text applies to any Codex or other code agent once adopted. Existing `AGENTS.md` always takes precedence until reconciled; do not overwrite it.

## Task opening — mandatory on every Codex prompt

**Read `AGENTS.md`, `docs/CONTRACTS.md`, the relevant existing files, and `git status` first. Inspect and explain before editing. If a referenced contract/file is missing or conflicts with actual code, STOP and report; never silently generate replacements.**

Exception: a deliberately approved **phase-0 read-only repo audit** may examine absence of these files and report it without editing; it must not bootstrap them automatically.

## Workspace

- Execute under WSL Ubuntu using VS Code WSL remote; confirm `uname -s` is `Linux`, `pwd -P` is a Linux-native path (not `/mnt/c`), and repository root is from `git rev-parse --show-toplevel`.
- Never change `/home/arnav/project_1`, any unrelated coursework, other repos, user home root, system config, Windows files or private directories. No work outside the verified SysGuard repo (except explicit temporary test directories under `/tmp`).
- User's GitHub remote URL, username, teammate names, packages and mail transport are not known until inspected. Never invent them.

## Permissions and prohibited operations

- First explain which files you plan to touch and which contract clauses they implement. Change only approved owned files within the current phase. Request review for shared interfaces.
- Do not install packages, edit system service config, install/remove cron entries, send actual email, interact with credentials, commit/push/merge, or access unrelated files without explicit separate human permission.
- Never run `git push --force`, `git reset --hard`, `git clean -fd`, destructive `rm`, or broad recursive cleanup; never reset, overwrite or delete uncommitted user work. Never overwrite `.env`, `config/local.conf`, SSH keys, passwords or local crontab without consent.
- Do not run load/stress tests that intentionally fill a disk, exhaust RAM, or attack the system. Use synthetic fixtures and a mock delivery backend in tests.
- Do not fabricate results. Actual `bash -n`, ShellCheck, unit or integration test outcomes must be reported with precise commands and exit status. An unavailable dependency is “not tested,” not “passed.”

## Ownership and proposed responsibility

- Janardhan Reddy: `scripts/monitor.sh`, `scripts/main.sh`, config templates, baseline `AGENTS.md`, `docs/CONTRACTS.md` after unanimous review, common fixtures, `tests/test_monitor.sh`, `tests/run_all.sh`, top-level README and Git conventions.
- Chetan Yalla: `scripts/alerts.sh`, `scripts/setup_cron.sh`, `tests/test_alerts.sh`, `tests/test_cron.sh`, `docs/OPERATIONS.md`.
- Arnav Nakka: `scripts/report.sh`, `scripts/rotate_logs.sh`, `tests/test_reports.sh`, `tests/test_rotation.sh`, `docs/REPORTS.md`; optional static dashboard only after approval.
- No one silently edits another role's modules or alters approved CSV header, CLI flags, exit codes, config keys, report date semantics, lock path, or fixtures. Interface changes require a team decision and new contract/fixture version.

## Engineering quality bar

- Bash with `#!/usr/bin/env bash`, clear functions, quoted variable expansions and safe filename handling; simple understandable `awk`; no inappropriate `eval`; use `LC_ALL=C` where numeric parsing depends on locale.
- `flock` where coordinated writes/rotation matter, temp-file + atomic move for state/reports, meaningful exit codes and diagnostics on stderr.
- Monitoring uses two `/proc/stat` deltas, `MemTotal/MemAvailable`, `df -P`; no fake readings on failure. Email test mode is mock and cannot send. Reports aggregate real/fixture CSV across archives without duplicating rows.
- Use `bash -n`; run ShellCheck if available; write deterministic, isolated, idempotent tests with temp files. Do not assert real SMTP delivery from a mock.
- At end of each phase: (1) actual files changed, (2) diff summary, (3) actual test commands/results, (4) remaining issues, (5) explicit gate/approval required for next phase. Do not start next phase automatically.

## Work order

0. Audit existing work, official brief, repo, deps, and contracts **read-only**.
1. Approve roles, repo, fixture v1, contracts, and agent rules as a reviewed baseline.
2. Implement Janardhan Reddy's monitor. Chetan Yalla and Arnav Nakka then independently use approved fixture v1.
3. Merge via reviewed PRs; run integrated checks, genuine mail and cron acceptance only with user permission.
4. Generate release/viva evidence; consider dashboard only after mandatory functionality works.