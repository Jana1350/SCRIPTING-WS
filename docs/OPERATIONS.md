# SysGuard alert and cron operations

This checkout contains Member B's two entry points and their tests. Run the tests here without A's collector, C's reporting tools, mailx, or a cron daemon. Production requires the integrated SysGuard Git checkout, A's configuration and genuine metrics. Commands below assume Bash on Linux/WSL with Git, GNU coreutils, awk and util-linux flock.

## Read a sample

Run `scripts/alerts.sh --once` after A's collector succeeds. Relative paths resolve from the Git root containing the script. By default it loads `config/defaults.conf` followed by optional `config/local.conf`. An explicit `--config FILE` selects the override in place of local.conf, or supplies the complete configuration in a standalone checkout. Configuration is parsed as literal key/value data. The isolated test configuration illustrates the required v1 keys.

The engine takes the exclusive `runtime/alerts.lock` and snapshots the exact header and final row of `data/metrics.csv` under a shared `runtime/metrics.lock`. A and C must use that same metrics lock when writing or rotating. `--data-dir DIR` changes the metrics and alert directory. Locks stay under the Git root. A busy lock returns immediately.

The exact header is `timestamp,cpu_percent,memory_percent,disk_percent`. The last row must end in a newline and contain a valid calendar timestamp with a numeric offset and three percentages in [0.0, 100.0], each with one fractional digit. A sample exactly MAX_DATA_AGE_SECONDS old is eligible. Future tolerance is zero. An invalid latest row causes an input error even when an earlier row is valid. A owns ordering within the CSV. B also rejects a sample older than its saved instant or with different field values at the same instant.

## State and notification history

On first observation each metric starts from NORMAL. At or above its configured warning or critical threshold it escalates immediately. On the way down it holds its current state at equality with the threshold minus hysteresis. After leaving CRITICAL it remains WARNING until it is below the warning recovery boundary. For warning 75, critical 90 and hysteresis 2, the sequence 75, 90, 88, 87.9, 73, 72.9 produces WARNING, CRITICAL, CRITICAL, WARNING, WARNING, NORMAL.

Under the selected data directory, `alerts/state.tsv` has three headerless rows in CPU, memory, disk order. Each stores metric, last sample timestamp, severity and original percentage, separated by tabs. `alerts/events.csv` records every escalation, downgrade and recovery. The threshold column records the crossed boundary for leaving the prior state or entering the escalated state. The event ID used for delivery combines metric, sample timestamp and new severity.

Changes are staged on the output filesystem. A rename publishes a pending transaction, then the script replaces event history and state under the alert lock. If interrupted during those replacements, the next invocation finishes them before processing another sample. Readers requiring a consistent view should use the alert lock and check for a pending transaction. Corrupt state requires operator review. Preserve the files before repairing them. The process-interruption test covers rename recovery. Power-loss durability depends on the filesystem and has not been tested.

Each transition is eligible for one notification. Mock is the default. It captures recipient, subject and body in `alerts/mock-mail.log`. Disabled mode records suppression. `alerts/delivery.csv` links each attempt and outcome to its event. A failed capture or mail submission retains the transition. Reprocessing the sample does not retry it. An interruption between publication and delivery can leave an event without a delivery record. An interrupted attempt can leave only a started record. Review those IDs manually before considering a resend.

| Exit | Meaning |
|---|---|
| 0 | Sample handled, preview printed or requested cron operation complete |
| 2 | Usage or configuration error |
| 3 | Missing, malformed, future, stale or conflicting sample |
| 4 | I/O error, corrupt state or unsafe crontab |
| 5 | Delivery failed after the transition was recorded |
| 6 | Lock busy or detected concurrent crontab edit |
| 7 | Required dependency unavailable or unsupported |

## Cron preview and live acceptance

Run `scripts/setup_cron.sh` or `scripts/setup_cron.sh --print` to print the block. Preview also works before the shared configuration and A/C commands arrive. With explicit `--config FILE`, the preview validates the configuration and passes its absolute path to each job.

| Daemon local time | Job |
|---|---|
| Every minute | main.sh --once |
| Daily 00:10 | report.sh daily |
| Monday 00:20 | report.sh weekly |
| Daily 00:30 | rotate_logs.sh |

Each command uses an absolute executable path, Bash and a job-scoped PATH. The minute job skips an overlapping run. Reports and rotation wait on the same cron lock. Output goes to `runtime/cron.log`. Before a job starts, a log at least 1 MiB is renamed to cron.log.1, replacing the previous backup. A single job may exceed that size.

Live scheduling is unverified. After integration, confirm A calls alerts only after successful collection, verify the scripts are executable, inspect the daemon's timezone and status, and review the preview and existing crontab. Only a separately authorized operator should run `scripts/setup_cron.sh --install`. Inspect the resulting table and observe a scheduled run in the log while WSL is running. A stopped WSL instance can miss jobs. Separately authorized `--uninstall` removes the marked block. Setup preserves unrelated lines, rejects duplicate or unbalanced markers and rechecks the table before writing. Avoid concurrent external edits because crontab has no compare-and-swap operation.

## Real-mail acceptance

Real mail has not been exercised. It requires explicit `--mail-mode real`, MAIL_ENABLED=1, a validated single EMAIL_TO address, and a mailx variant whose help advertises the subject option. An operator must separately verify the installed variant and configured transport and obtain consent for one controlled test. Review the event and attempt records, the mail transport logs and recipient confirmation. A submitted record means mailx exited successfully. Only the recipient can confirm inbox receipt. No credentials belong in these files.

## Isolated checks

Run from the standalone or integrated repository root.

```bash
bash -n scripts/alerts.sh
bash -n scripts/setup_cron.sh
bash tests/test_alerts.sh
bash tests/test_cron.sh
git diff --check
```

Both suites create temporary checkouts. The alert test freezes the current second, supplies isolated CSV data, and forces a mock capture failure with /dev/full. The cron test installs a fake crontab first on PATH, exercises install and uninstall against temporary files, and runs rendered commands against fixture executables. Real email, daemon execution, A/C integration and WSL restart behavior require separate acceptance.
