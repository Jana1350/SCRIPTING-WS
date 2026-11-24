# SysGuard

SysGuard samples CPU, memory, and filesystem usage on WSL Ubuntu and records complete measurements in a CSV. Member A owns the Bash monitor, configuration, and orchestration. Member B owns alerts, email, and cron. Member C owns reports, charts, and log rotation. The shared interface in [docs/CONTRACTS.md](docs/CONTRACTS.md) is provisional pending formal team review.

## Run SysGuard locally

On Ubuntu or WSL Ubuntu, open a terminal as the Linux user who should own the files and scheduled jobs. You need Git access to clone the project. Setup runs on your machine and requires no device registration.

```bash
git clone https://github.com/Jana1350/SCRIPTING-WS.git
cd SCRIPTING-WS
bash scripts/setup.sh
```

Already cloned? Run the last command from your checkout. Press Enter to skip an optional action, including on repeat runs. For a first sample, answer **yes** to the monitoring check. It uses Bash, Linux `/proc`, GNU coreutils, awk and flock. It writes the measurement to `data/metrics.csv` and processes alerts locally in mock mode. Check it with `bash scripts/main.sh --status` and `tail -n 2 data/metrics.csv`.

- **Personal email is optional.** Start with mock delivery. For Gmail, arrange a working outgoing transport for the same Linux user, for example Ubuntu GNU Mailutils with a sendmail-compatible msmtp setup. Configure authenticated SMTP with TLS in the transport's private settings outside Git. On Ubuntu, the packages for this route are `mailutils`, `msmtp` and `msmtp-mta`. Configure the transport for `smtp.gmail.com` on port 587 with STARTTLS. If your account permits app passwords, enable two-step verification and follow [Google’s app password instructions](https://support.google.com/accounts/answer/185833). Keep the secret in your transport’s protected credential store. The wizard checks mailx subject support, asks before submitting one test, and asks you to confirm inbox receipt before it saves the recipient in the ignored `config/local.conf`. A real scheduled alert also requires explicit real-mail mode. Rerun setup to verify mail when ready.
- **Change who receives alerts.** The sender is saved once in the Linux user’s mail transport. Rerun `bash scripts/setup.sh`, choose personal email setup, and choose to change the existing recipient. Enter the new inbox and confirm the test message before switching scheduled alerts. To stop email, enter `OFF` at the recipient prompt and confirm. The wizard clears the recipient and keeps scheduled monitoring and local reports running in mock mode.
- **Scheduling is optional.** Install the Ubuntu cron package and check `systemctl is-active cron` if using systemd. Setup previews the jobs before asking to install them for the current user. On WSL, the distribution and daemon must be running and the laptop awake when a job is due. Inspect `runtime/cron.log` after a scheduled run. Remove only SysGuard's managed block with `bash scripts/setup_cron.sh --uninstall`.
- **Reports arrive on schedule.** Monitoring runs each minute. The first scheduled daily report covers the previous day at the next 00:10 local time. Weekly reports cover the previous Monday–Sunday at 00:20 Monday. Look in `reports/daily/`, `reports/weekly/` and `reports/charts/`. At 00:30 daily, rotation archives completed days under `data/archive/`. Reports with samples need gnuplot with pngcairo and a font. Rotation needs gzip. PDF output is enabled by default and requires a compatible WeasyPrint (tested with 67.0), file and Poppler utilities on the cron PATH (`/usr/bin:/bin`). See [report dependencies](docs/REPORTS.md#dependencies).

## Run the monitor

From the repository root, this example takes one real sample in a new temporary directory and checks where it was written.

```bash
sample_dir=$(mktemp -d)
scripts/monitor.sh --once --config config/example.local.conf --data-dir "$sample_dir"
scripts/main.sh --status --config config/example.local.conf --data-dir "$sample_dir"
```

The monitor prints one CSV row to stdout after successful publication. Config messages and failures go to stderr. The example leaves the temporary directory available for inspection. With default options, the active file is `data/metrics.csv`. Relative CLI paths resolve against the repository root.

| Command | Behavior |
|---|---|
| `scripts/monitor.sh --help` | Show monitor syntax. |
| `scripts/monitor.sh --once` | Collect and publish one complete sample. A busy metrics lock ends the command with exit code 6. |
| `scripts/monitor.sh --watch` | Start sampling immediately. The start-to-start interval includes the CPU sampling delay. Ctrl-C or SIGTERM stops the foreground watch gracefully. |
| `scripts/main.sh --help` | Show orchestration syntax. |
| `scripts/main.sh --status` | Validate config and report whether the metrics file is present. A missing file before the first sample is a successful status check. Presence alone gives no assurance about freshness or contents. |
| `scripts/main.sh --once` | Check that both child executables exist. Run the monitor, then invoke `alerts.sh --once` only after successful collection. An alert failure leaves the collected row in place. |
| `scripts/main.sh --report daily` or `scripts/main.sh --report weekly` | Delegate the selected period to `report.sh` and propagate its exit status. |

All operational modes accept optional `--config FILE` and `--data-dir DIR`. Use `--help` alone.

If the metrics lock is busy at publication, watch prints `warning: metrics lock is busy, skipping this sample` to stderr and discards that sample. It starts a fresh measurement at the next scheduled interval. Missed starts are skipped, so prolonged contention leaves gaps in the CSV. Other errors end watch with their usual exit codes, including exit 4 for a lock-operation failure.

## Read a measurement

The header and the following **fixture example** show the column order and precision.

```csv
timestamp,cpu_percent,memory_percent,disk_percent
2026-11-20T08:00:00+05:30,74.9,50.0,40.0
```

Each row has a timestamp with a numeric UTC offset and three percentages from 0.0 to 100.0. The monitor uses the C locale for decimal formatting. It compares timestamps as instants and rejects an equal or earlier timestamp in the active file.

- **CPU** is average busy time across the aggregate Linux CPU counters over two reads of `/proc/stat`, one second apart by default. Sum user, nice, system, idle, iowait, irq, softirq, and steal for each read. Guest time is already included in user and nice. Compute `100 × (1 − Δ(idle + iowait) / Δtotal)`. A decreasing counter or zero total delta fails the sample. Fully idle and fully busy intervals give valid 0.0 and 100.0 readings.
- **Memory** is `100 × (MemTotal − MemAvailable) / MemTotal` from `/proc/meminfo`. Available memory includes reclaimable memory. A missing or duplicated field, zero total, or available memory above total fails the sample.
- **Disk** is the integer `Use%` from `df -P`, formatted to one decimal. Set `DISK_MOUNT` to the accessible mount point itself. The reported mount must match the configured canonical directory.

These readings describe the Linux environment visible inside WSL. Windows host memory use and physical disk I/O are outside their scope. Sampling requires a running WSL instance. A stopped watch leaves a gap in the history.

## Configuration and CSV integrity

The monitor loads [config/defaults.conf](config/defaults.conf), then applies [config/example.local.conf](config/example.local.conf) only if explicitly selected. Normally the override is the optional, Git-ignored `config/local.conf`. An explicit `--config FILE` selects the override for that invocation. Use trusted, non-executable `KEY=value` files. The parser accepts known keys, rejects duplicates within a file, and does not evaluate shell commands. Keep credentials out of these files and Git.

Defaults use a one-second CPU sample, a 60-second watch interval, and the root mount. Warning/critical defaults are 75/90 for CPU and memory and 80/95 for disk. Each warning must be below its critical threshold, the watch interval must exceed the sampling delay, and the maximum data age must cover their sum. Thresholds are configuration for the alerts consumer. A monitor row contains measurements.

The writer takes an exclusive lock before opening the active CSV. It validates the active history, stages the complete updated file in the destination directory, then publishes it by rename. Sensor, validation, or staging failures preserve the previous CSV. The default data directory uses the persistent `runtime/metrics.lock`. Other canonical data directories use their own `.metrics.lock`. Rotation must use the same lock inode. Atomic publication has been tested. Power-loss durability remains unverified.

## Real email alerts

External email delivery is disabled by default. `scripts/main.sh --once` and the default cron monitoring job still evaluate alerts, record transitions, and capture mock delivery locally. Real delivery requires both `MAIL_ENABLED=1` in the effective configuration and an explicit `--mail-mode real` option. Put the single recipient in `EMAIL_TO` in your Git-ignored `config/local.conf`. Keep local configuration outside Git and keep SMTP credentials in the mail transport's own configuration.

- `scripts/main.sh --once --mail-mode real` validates the real-mail configuration before starting collection. Invalid configuration returns `2` before any metrics or alert records change. After successful collection, alerts use the validated settings. A transport submission failure returns `5` and preserves the collected sample, alert state, and events. The delivery history records the failed attempt.
- `scripts/setup_cron.sh --print --mail-mode real` validates the configuration and previews the cron block. The real-mail option applies only to the monitoring job.
- `scripts/setup_cron.sh --install --mail-mode real` installs that block after you have reviewed the preview and authorized installation. Preview and install accept `--config FILE` when you need an explicit override.
- `scripts/setup_cron.sh --uninstall` removes the managed block. It accepts `--config FILE` for compatibility and skips configuration loading.

Real delivery requires a `mailx` variant that advertises `-s` in its help and a working outgoing mail transport. Cron jobs use `PATH=/usr/bin:/bin`, so `mailx` must be available on that path for scheduled delivery. On WSL the cron daemon and Linux instance must be running when the job is scheduled. A `submitted` entry records a successful `mailx` exit. Inbox delivery requires separate confirmation. Automated tests use fake mail and crontab commands. Live SMTP delivery and cron execution require separate verification. See [alert and cron operations](docs/OPERATIONS.md) for operational details.

## Exit codes

| Code | Meaning |
|---:|---|
| 0 | Success, help, or graceful watch shutdown |
| 2 | Invalid arguments or configuration |
| 3 | Invalid measurement, CSV, or timestamp. The test runner also uses 3 for an incompatible v1 fixture. |
| 4 | Filesystem, publication, or lock-operation failure |
| 5 | Mail delivery failure propagated from the alerts child |
| 6 | Metrics lock already held during one-shot collection |
| 7 | Required command or child executable unavailable |

## Run and interpret tests

```bash
tests/test_monitor.sh
tests/run_all.sh
```

Run the first command for Member A's suite. It uses temporary directories, deterministic sensor inputs, and test-only child executables. The signal checks use Python 3. The second command checks the shared fixture against contract C9 before running available suites. A changed fixture exits before any suite starts. A `SKIP` line identifies an unavailable suite.

Member A's tests use a real advisory lock and a controlled clock to check that watch skips contended samples and publishes a fresh row on schedule after release. They also exercise simulated rotation. Delegation tests verify arguments and exit propagation with temporary stand-ins. Use the full runner's output for the suite results in your checkout.
