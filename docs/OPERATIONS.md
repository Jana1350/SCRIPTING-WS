# SysGuard alert and cron operations

The alert and cron entry points use the shared configuration loader in `scripts/config.sh`. The isolated suites use fixtures for scheduled commands and mail transport. Production requires the integrated SysGuard Git checkout, shared defaults and genuine metrics. Commands below assume Bash on Linux/WSL with Git, GNU coreutils, awk and util-linux flock.

## Read a sample

Run `scripts/alerts.sh --once` after A's collector succeeds. Relative paths resolve from the Git root containing the script. By default it loads `config/defaults.conf` followed by optional `config/local.conf`. An explicit `--config FILE` selects the override in place of local.conf, or supplies the complete configuration in a standalone checkout. The shared loader parses literal key/value data and returns exit 4 for unreadable selected files. A direct alert invocation can use a complete explicit configuration when shipped defaults are absent. An invocation that runs the collector requires shipped defaults and validates before calling it.

Alerts takes the exclusive `runtime/alerts.lock` first, then a shared metrics lock before recovering pending state or opening the CSV. The repository data directory uses `runtime/metrics.lock`, including an explicit `--data-dir ./data/.` or the equivalent absolute path. Any other selected directory uses its own `.metrics.lock`. These paths match the collector, reporter and rotator. Contention on either lock returns 6 immediately and leaves any pending publication for the next run. Alerts releases the metrics lock after validating the header and latest sample. It keeps the alert lock through state publication and delivery.

Both locks use non-truncating opens with a private creation mask. Existing files keep their bytes and inode. Alerts requires regular, singly linked lock files and rejects symbolic links in data, alert-output and runtime directory paths with exit 4. Keep these directories and their ancestors under trusted ownership. The Bash implementation checks path components and compares the opened descriptor to the named file, but a process with directory write access can still swap a path between checks or after acquisition. Never rename or unlink a live lock.

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

Run `scripts/setup_cron.sh` or `scripts/setup_cron.sh --print` to print the block. An unconfigured checkout can print the default mock schedule. Configured previews and all installations require the shipped defaults and validate before rendering or accessing the crontab. With explicit `--config FILE`, the preview validates the configuration and passes its absolute path to each job.

| Daemon local time | Job |
|---|---|
| Every minute | main.sh --once |
| Daily 00:10 | report.sh daily |
| Monday 00:20 | report.sh weekly |
| Daily 00:30 | rotate_logs.sh |

The minute job tries `runtime/cron-monitor.lock`. Daily and weekly reports and rotation all try `runtime/cron-maintenance.lock`. A busy job lock skips that invocation immediately with exit 6. Monitoring can therefore collect while a report is rendering. The underlying project commands still coordinate CSV access through the metrics lock, and A’s orchestrator calls alerts only after successful collection.

The generated entries use absolute paths, Bash and a job-scoped PATH. Each records command output in `runtime/cron.log`. Skips identify the job and busy lock, or an exit 6 from the project command. Other failures identify the job and command exit code. Missed jobs require a later run. Before opening the log, jobs serialize its size check and rename using a lock on the runtime directory with a two-second timeout. At 1 MiB they rename the log to `cron.log.1`, replacing the previous backup. A command already writing at rotation can continue writing to the renamed file.

On the existing UTC WSL deployment, the installed four-job block matched the real-mail preview, and the unrelated crontab entries matched the pre-install backup. Syslog and the SysGuard log confirmed consecutive automatic monitoring runs and corresponding UTC CSV rows. Daily and weekly HTML/PDF generation and rotation passed in isolated acceptance tests.

Only a separately authorized operator should run `scripts/setup_cron.sh --install`. Inspect the resulting table and observe scheduled jobs in the log while WSL is running. A stopped WSL instance can miss jobs. Separately authorized `--uninstall` removes the marked block and skips configuration loading. Setup preserves unrelated lines, rejects duplicate or unbalanced markers and rechecks the table before writing. Avoid concurrent edits because crontab has no compare-and-swap operation.

## Real-mail acceptance

On the existing deployment, the operator confirmed Gmail receipt after a manual mail submission, a controlled SysGuard threshold test, and a cron-originated memory threshold alert. These are deployment results. The regression suites exercise the mail path with a capture stub. Real delivery requires explicit `--mail-mode real`, MAIL_ENABLED=1, a validated single EMAIL_TO address, and a mailx variant whose help advertises the subject option. An operator must separately verify the installed variant and configured transport and obtain consent for one controlled test. Review the event and attempt records, the mail transport logs and recipient confirmation. A submitted record means mailx exited successfully. Only the recipient can confirm inbox receipt. No credentials belong in these files.

## Isolated checks

Run from the standalone or integrated repository root.

```bash
bash -n scripts/alerts.sh
bash -n scripts/setup_cron.sh
bash tests/test_alerts.sh
bash tests/test_cron.sh
git diff --check
```

Both suites create temporary checkouts. The alert test freezes the current second, supplies isolated CSV data, and forces a mock capture failure with /dev/full. The alert lock regressions also cover the default and custom lock paths, contention, and unsafe targets with seeded state and lock bytes. The cron test installs a fake crontab first on PATH, exercises install and uninstall against temporary files, and runs rendered commands against fixture executables. By default its collector fixture implements the metrics-lock policy and calls the real alerts script. Set `SYSGUARD_TEST_MONITOR_SCRIPTS` to a directory containing A’s executable `main.sh` and `monitor.sh` to repeat the scheduled contention checks with those scripts copied into the temporary repository. Report and rotation commands in this suite are fixtures. The fixtures include the shared loader. WSL restart and catch-up behavior require separate acceptance.
