# SysGuard

SysGuard samples CPU, memory, and filesystem usage on WSL Ubuntu and records complete measurements in a CSV. Janardhan Reddy owns the Bash monitor, configuration, and orchestration. Chetan Yalla owns alerts, email, and cron. Arnav Nakka owns reports, charts, and log rotation. The shared interface is specified in [docs/CONTRACTS.md](docs/CONTRACTS.md).

## Terminal control center (V1.1)

Run `bash sysguard.sh` from the V1.1 checkout. Use **1** or **5** for local settings, **3** to collect a sample, **6** to generate reports, **7** to view them, and **9** to inspect status. When another checkout owns cron, **1** offers local recipient and threshold settings and keeps that schedule active. [Full numbered menu](docs/CONTROL_CENTER.md)

- **First run.** A fresh clone can collect metrics and capture mock alerts with the tracked defaults. Use **5 → 1** to set the recipient and **5 → 2** to enable real mail in this checkout. The existing sender comes from the Linux user's mail transport. A new machine needs its own working SMTP transport for real email.
- **Real mail is opt-in per operation.** Option **3** asks before manual real processing. Option **2** asks separately about scheduled real mail and cron installation. Only qualifying new alert transitions cause a submission. The delivery ledger can confirm mailx accepted a submission. Check inbox receipt separately.
- **Reports.** Use **6 → 1** for a partial UTC report in `reports/today/`. The other choices cover the previous completed day or Monday–Sunday week. Use **7** to select an existing PDF, folder, HTML report, or chart. Opening requires confirmation. The launcher prints the absolute path and a fallback command when the opener is unavailable or fails.

## Run SysGuard locally

On Ubuntu or WSL Ubuntu, open a terminal as the Linux user who should own the files and scheduled jobs. A fresh machine needs Git access, Bash, awk, GNU coreutils, Linux procfs, and util-linux flock for local monitoring. The wizard checks the environment. Install the optional scheduling, report, and mail dependencies for the features you intend to use.

```bash
git clone https://github.com/Jana1350/SCRIPTING-WS.git
cd SCRIPTING-WS
bash scripts/setup.sh
```

Already cloned? Run the last command from your checkout. Press Enter to skip an optional action, including on repeat runs. For a first sample, answer **yes** to the monitoring check. It uses Bash, Linux `/proc`, GNU coreutils, awk and flock. It writes the measurement to `data/metrics.csv` and processes alerts locally in mock mode. Check it with `bash scripts/main.sh --status` and `tail -n 2 data/metrics.csv`.

- **Personal email is optional.** Start with mock delivery, which needs no Gmail credentials. The wizard never configures SMTP or prompts for a password. For Gmail, arrange a working outgoing transport for the same Linux user, for example Ubuntu GNU Mailutils with a sendmail-compatible msmtp setup. Configure authenticated SMTP with TLS in the transport's private settings outside Git. On Ubuntu, the packages for this route are `mailutils`, `msmtp` and `msmtp-mta`. Configure the transport for `smtp.gmail.com` on port 587 with STARTTLS. If your account permits app passwords, enable two-step verification and follow [Google’s app password instructions](https://support.google.com/accounts/answer/185833). Keep the secret in your transport’s protected credential store. The wizard checks mailx subject support, asks before submitting one test, and asks you to confirm inbox receipt before it saves the recipient in the ignored `config/local.conf`. A real scheduled alert also requires explicit real-mail mode. Rerun setup to verify mail when ready.
- **Change who receives alerts.** The sender is saved once in the Linux user’s mail transport. Rerun `bash scripts/setup.sh`, choose personal email setup, and choose to change the existing recipient. Enter the new inbox and confirm the test message before switching scheduled alerts. To stop email, enter `OFF` at the recipient prompt and confirm. The wizard clears the recipient and switches an existing real schedule to mock before publishing the change. If cron cannot update, the wizard preserves the previous mail settings. If cron switches to mock but saving the settings fails or setup is interrupted, leave the schedule in mock. Rerun setup, select `OFF`, and confirm clearing the recipient. Setup never automatically restores real-mail scheduling.
- **Schedules with explicit configuration.** If an installed job uses `--config FILE`, the wizard preserves the schedule and skips local recipient changes. An explicit real-mail schedule remains enabled when wizard email setup is skipped. Use the original config to preview and deliberately apply a mock schedule as described in [operations](docs/OPERATIONS.md#cron-preview-and-live-acceptance).
- **Keep local config private.** A fresh checkout needs no `config/local.conf`. If one exists, it must be an ignored, untracked, owned regular file with one link and mode 0600 or 0400. The config directory must be owned by the current Linux user and permit writes only by that user. For an owned regular file with one link, use `chmod 600 config/local.conf`. Replace symlinks and unsupported files before running setup. If broken config blocks startup, use `bash scripts/setup_cron.sh --uninstall` to remove only SysGuard’s managed jobs.
- **Scheduling is optional.** Install the Ubuntu cron package and check `systemctl is-active cron` if using systemd. Setup previews the jobs before asking to install them for the current user. On WSL, the distribution and daemon must be running and the laptop awake when a job is due. Inspect `runtime/cron.log` after a scheduled run. Remove only SysGuard's managed block with `bash scripts/setup_cron.sh --uninstall`.
- **Reporting and rotation schedule.** V1.0 uses UTC for the scheduler, collector, reports, and rotation. The jobs are configured for monitoring every minute, the prior day’s report at 00:10 UTC, the prior Monday–Sunday report on Mondays at 00:20 UTC, and archiving completed days at 00:30 UTC. Reports with samples need gnuplot with pngcairo and a font. PDF output is enabled by default and requires compatible WeasyPrint, file and Poppler utilities. Rotation needs gzip. Use `rotate_logs.sh --dry-run` to preview retention candidates. Old archives are never deleted by rotation. Scheduled commands use `/usr/bin:/bin`. See [report dependencies](docs/REPORTS.md#dependencies) and [deployment evidence](docs/DEPLOYMENT-ACCEPTANCE.md).

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

Defaults use a one-second CPU sample, a 60-second watch interval, and the root mount. Warning/critical defaults are 75/90 for CPU and memory and 80/95 for disk. Each warning must be positive and strictly below its critical threshold, which cannot exceed 100. Hysteresis must be 0–20 and strictly below every warning. Recovery uses a strict comparison below the threshold minus hysteresis. The watch interval must exceed the sampling delay, and the maximum data age must cover their sum. Zero-valued measurements remain valid.

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
bash tests/test_monitor.sh
bash tests/run_all.sh
```

Run the first command for Janardhan Reddy's suite. It uses temporary directories, deterministic sensor inputs, and test-only child executables. The signal checks use Python 3. The second command checks the shared fixture against contract C9 before running all seven required suites. Successful completion prints `Suites: 7 passed, 0 skipped`. A missing suite fails the runner. Report tests require the renderer and PDF inspection dependencies listed above.

Janardhan Reddy's tests use a real advisory lock and a controlled clock to check that watch skips contended samples and publishes a fresh row on schedule after release. They also exercise simulated rotation. Delegation tests verify arguments and exit propagation with temporary stand-ins. Use the full runner's output for the suite results in your checkout.
