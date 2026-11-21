# SysGuard

SysGuard samples CPU, memory, and filesystem usage on WSL Ubuntu and records complete measurements in a CSV. Member A owns the Bash monitor, configuration, and orchestration. Member B owns alerts, email, and cron. Member C owns reports, charts, and log rotation. The shared interface in [docs/CONTRACTS.md](docs/CONTRACTS.md) is provisional pending formal team review.

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
| `scripts/monitor.sh --once` | Collect and publish one complete sample. |
| `scripts/monitor.sh --watch` | Start sampling immediately. The start-to-start interval includes the CPU sampling delay. Missed starts are skipped. Ctrl-C or SIGTERM stops the foreground watch gracefully. A failed cycle, including lock contention, ends the watch with its failure code. |
| `scripts/main.sh --help` | Show orchestration syntax. |
| `scripts/main.sh --status` | Validate config and report whether the metrics file is present. A missing file before the first sample is a successful status check. Presence alone gives no assurance about freshness or contents. |
| `scripts/main.sh --once` | Check that both child executables exist. Run the monitor, then invoke `alerts.sh --once` only after successful collection. An alert failure leaves the collected row in place. |
| `scripts/main.sh --report daily` or `scripts/main.sh --report weekly` | Delegate the selected period to `report.sh` and propagate its exit status. |

All operational modes accept optional `--config FILE` and `--data-dir DIR`. Use `--help` alone.

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

Defaults use a one-second CPU sample, a 60-second watch interval, and the root mount. Warning/critical defaults are 75/90 for CPU and memory and 80/95 for disk. Each warning must be below its critical threshold, the watch interval must exceed the sampling delay, and the maximum data age must cover their sum. Thresholds are configuration for the alerts consumer. A monitor row contains measurements. Mail is disabled by default.

The writer takes an exclusive lock before opening the active CSV. It validates the active history, stages the complete updated file in the destination directory, then publishes it by rename. Sensor, validation, or staging failures preserve the previous CSV. The default data directory uses the persistent `runtime/metrics.lock`. Other canonical data directories use their own `.metrics.lock`. Rotation must use the same lock inode. Atomic publication has been tested. Power-loss durability remains unverified.

## Exit codes

| Code | Meaning |
|---:|---|
| 0 | Success, help, or graceful watch shutdown |
| 2 | Invalid arguments or configuration |
| 3 | Invalid measurement, CSV, or timestamp. The test runner also uses 3 for an incompatible v1 fixture. |
| 4 | Filesystem, publication, or lock-operation failure |
| 5 | Mail delivery failure propagated from the alerts child |
| 6 | Metrics lock already held |
| 7 | Required command or child executable unavailable |

## Run and interpret tests

```bash
tests/test_monitor.sh
tests/run_all.sh
```

Run the first command for Member A's suite. It uses temporary directories, deterministic sensor inputs, and test-only child executables. The signal checks use Python 3. The second command checks the shared fixture against contract C9 before running available suites. A changed fixture exits before any suite starts. A `SKIP` line identifies an unavailable suite.

The current checkout passes Member A's suite and skips the four suites for alerts, cron, reports, and rotation. Delegation tests verify arguments and exit propagation with temporary stand-ins. The lock test exercises a simulated rotation. Real email delivery, cron execution, HTML/PDF generation, actual log rotation, and timestamp continuity across archives remain unverified. Until the corresponding child executables are available, `main.sh --once` and both report modes return 7.
