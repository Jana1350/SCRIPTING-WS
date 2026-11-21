# Draft for future `docs/CONTRACTS.md` — SysGuard Shared API v1

**STATUS: PROPOSED, NOT APPROVED OR INSTALLED.** All three members must review this together, compare with any existing code, sign off, and commit a versioned baseline **before** independent implementation. No contracts change without a team review and a fixture version bump where behavior changes. This is a **draft text file for planning**, not evidence that `docs/CONTRACTS.md` exists in Ubuntu.

## C0. Goals and terminology

One immutable interface for producer A (monitor), consumers B/C (alerts/reports), and C's log rotation. This contract describes a **WSL Ubuntu system-health monitor**; “real time” means periodic sampling with explicit latency, not uninterrupted hardware telemetry.

- `REPO_ROOT`: value of `git rev-parse --show-toplevel`, discovered in a **verified** SysGuard repository. No hard-coded user name, checkout name or GitHub URL.
- All CLI paths with no leading slash resolve **relative to `REPO_ROOT`**. All scripts use stable path discovery based on script location, not current working directory.
- Exit codes across scripts: **0** success (including valid zero-row report labeled no data); **2** usage or invalid config; **3** measurement/invalid input/stale sample; **4** filesystem/write/read failure; **5** mail delivery failure; **6** lock busy; **7** unavailable dependency. A script may encounter more than one problem: report the primary error and exit nonzero. These are planned; approval needed.
- Diagnostics go to **stderr**, machine-meaningful results or short successful summaries to stdout. Never print secret material. In tests, assert exit and stderr category, not locale-specific message text.

## C1. Paths and ownership

| Path | Owner | Contract |
|---|---|---|
| `config/defaults.conf` | A | Reviewed non-secret defaults, tracked |
| `config/example.local.conf` | A | Example values, tracked; no live credentials |
| `config/local.conf` | Local user | Optional override, **ignored by Git**; never overwrite |
| `data/metrics.csv` | A append, C rotate | Production metrics; file can be absent before first collection |
| `data/archive/metrics-YYYY-MM-DD.csv.gz` | C | Archived CSV segment with header; rotation lock identical to monitor writer's |
| `data/alerts/state.tsv` | B | Durable per-metric alert state; atomic writes; ignored |
| `data/alerts/events.csv` | B | Append-only transitions; ignored |
| `data/alerts/delivery.csv` | B | One row for each delivery attempt/outcome; ignored |
| `reports/daily/YYYY-MM-DD.html` | C | Daily HTML for the **date represented**; ignored |
| `reports/daily/YYYY-MM-DD.pdf` | C | Daily PDF target, if configured and tool verified; ignored |
| `reports/weekly/YYYY-MM-DD_to_YYYY-MM-DD.html` | C | Prior complete Mon–Sun range; ignored |
| `reports/weekly/YYYY-MM-DD_to_YYYY-MM-DD.pdf` | C | Corresponding PDF target; ignored |
| `reports/charts/` | C | Deterministic generated PNGs/plots; ignored |
| `runtime/metrics.lock` | A monitor and C rotator | **Same advisory `flock` lock file**; never remove while processes use it |
| `runtime/alerts.lock` | B | One writer of alert state/events/deliveries |
| `runtime/report.lock` | C | Prevent overlapping report runs |
| `runtime/cron.lock` | B | Optional CLI/orchestrator overlap guard; scope defined during design |

**Critical rotation race:** `flock` protects active CSV append, truncate/rename, and archive creation. C must never unlink/recreate the lock inode casually. A must open active CSV **after acquiring** the shared lock, not retain an append descriptor across rotation; lock release is guaranteed on failure. Reports can read a consistent snapshot under lock, then release it before expensive chart rendering.

## C2. Metrics CSV v1

Literal header, exact order, one copy per CSV file:

```csv
timestamp,cpu_percent,memory_percent,disk_percent
2026-11-21T10:00:00+05:30,21.5,48.2,61.0
```

This example is **illustrative fixture material** and **not** a real computer measurement. Each actual sample has all three metrics from one collection cycle. Format:

1. Timestamp `%Y-%m-%dT%H:%M:%S%:z` (`+05:30` style) with **explicit numeric UTC offset**, no commas. Sample times are Unix-instant comparable after parsing; display timezone is explicitly configured/recorded. Default `date` local offset; `TZ` may be set for deterministic tests.
2. Three decimal numbers **one digit after decimal**, English ASCII decimal point, no `%`, no exponent, numeric range `[0.0,100.0]`. Use `LC_ALL=C` in scripts when parsing/calculating.
3. Comma-delimited, ASCII CSV, newline-terminated, **no quoted fields needed** because schema disallows commas/quotes/newlines within fields. Exactly four columns; no blank lines.
4. Rows must be **strictly increasing** by timestamp as an actual instant. The monitor must avoid appending duplicate or backwards time observations: if new timestamp is `<=` last timestamp, return a clear nonzero error, or define/approve a deterministic alternative. Repeated seconds can happen under watch interval <1s; the proposed default interval exceeds 1s.
5. File creation is atomic as practical: acquire lock; create parent with safe permissions; initialize exactly one header on first successful append; reject incorrect preexisting header; write each entire line as one append under lock; no row appended on any sensor failure. `umask 077` is appropriate for local data.
6. **Only A's monitor appends new real observations.** B/C never generate production samples. C may rotate a fully validated file under the same lock. Fixtures live under `tests/fixtures/v1/` and must never be silently mixed into `data/metrics.csv`.
7. A malformed **latest** row means B must report input error and **must not fall back** to an older good row. A missing or empty metrics file means no data, not a fake 0% reading. A timestamp older than `MAX_DATA_AGE_SECONDS` is stale; B must not send a new threshold alert based on stale input. C may skip malformed **historical** rows but must count and visibly disclose skipped rows; never claim a complete report if data is corrupted.
8. For reports read from archive + active log, sort/deduplicate only if needed, avoid counting the same row twice, and document any integrity errors. A single active-file/header archive duplicate due to rotation must not inflate aggregates.

### CPU accounting: correct algorithm

Read Linux `/proc/stat` `cpu` aggregate counter **twice** separated by `CPU_SAMPLE_SECONDS`. For the standard first eight fields: user, nice, system, idle, iowait, irq, softirq, steal; optionally `guest` and `guest_nice` appear later. Guest counts already contribute to user/nice in Linux accounting: **do not double-count guest fields**. Define `total = user + nice + system + idle + iowait + irq + softirq + steal`; define `idle_all = idle + iowait` (an approximation; Linux's iowait accounting is nuanced). Then:

`cpu_percent = 100 * (1 - (idle_all_2 - idle_all_1)/(total_2 - total_1))`.

Reject `Δtotal <= 0`, negative individual counters/invalid tokens, `Δidle < 0`, or any inconsistent delta. Clamp only tiny floating rounding deviations to [0,100], **do not conceal invalid inputs** by clamping arbitrary values.

### Memory

From `/proc/meminfo`: `used_percent = 100 * (MemTotal - MemAvailable)/MemTotal`. Require both values, integer `MemTotal > 0`, `0 <= MemAvailable <= MemTotal`, and no duplicates. Do not use `MemFree` as a substitute; memory available to new workloads includes reclaimable cache. WSL memory allocation behavior differs from Windows host usage.

### Disk

Use `df -P` for a validated configured mount path, normally `/`; select its `Use%` field and remove `%`. Robustly parse POSIX one-line output, check exit code, and avoid interpreting an arbitrary filesystem when the target mount/path is wrong. `df -P` is filesystem utilization, not physical SSD wear or raw I/O usage. Optional explicit `--` handling depends on `df` version; do not fabricate on failure.

## C3. Configuration schema v1

Tracked baseline `config/defaults.conf` example (**provisional values**):

```ini
CPU_WARNING=75
CPU_CRITICAL=90
MEMORY_WARNING=75
MEMORY_CRITICAL=90
DISK_WARNING=80
DISK_CRITICAL=95
DISK_MOUNT=/
CPU_SAMPLE_SECONDS=1
WATCH_INTERVAL_SECONDS=60
MAX_DATA_AGE_SECONDS=180
ALERT_HYSTERESIS_PERCENT=2
LOG_RETENTION_DAYS=30
EMAIL_TO=
MAIL_ENABLED=0
REPORT_PDF_ENABLED=1
```

- All values are examples, not instructor-mandated. **Apply defaults then local override**, validated before side effects. `CPU/MEMORY/DISK_WARNING`/`_CRITICAL`: integer percentages `0..100` and **warning < critical**. Hysteresis integer `0..20` and not so large that recovery thresholds are nonsensical. Positive integer sampling/interval/age/retention. Enforce `WATCH_INTERVAL_SECONDS > CPU_SAMPLE_SECONDS` and `MAX_DATA_AGE_SECONDS >= WATCH_INTERVAL_SECONDS + CPU_SAMPLE_SECONDS` or document intentionally tighter configurations.
- `DISK_MOUNT` must refer to an existing accessible path/mount; prefer `/` by default. Empty `EMAIL_TO` allowed only while mail disabled. `EMAIL_TO` must be a single validated destination address without whitespace/control chars or shell metacharacters; no embedded shell or mail arguments. When mail enabled, require user-confirmed transport. `REPORT_PDF_ENABLED` is a boolean, and enabling must verify an actual supported converter.
- Prefer a **strict `KEY=value` parser with an explicit key whitelist** and no `eval`; reject duplicate keys, unknown keys, embedded control characters, command substitutions or shell code. If the team chooses Bash `source` for simplicity, source **only files created/reviewed by the local operator**, never untrusted input, and explain the risk; never source a downloaded or externally supplied config as code.
- Runtime path overrides (`--config`, `--data-dir`, etc.) are for safe test isolation as well as operations. A `--config` filename must be validated and considered trusted. Log a clear message about which config loaded (without secrets).
- Ignore `config/local.conf` and `.env`, keys, runtime, reports, logs, temporary tests, backups. **Never commit credentials or SMTP passwords.** A recipient address is private config, not an authentication mechanism.

## C4. CLI v1 (proposed; freeze as written or revise with team BEFORE code)

| Command | Required actions and flags | Success / failure |
|---|---|---|
| `scripts/monitor.sh --once [--config FILE] [--data-dir DIR]` | Collect exactly one full sample, append CSV atomically, print concise metrics | 0 success; 2 invalid args/config; 3 sensor fail; 4 I/O; 6 lock busy; 7 dependency |
| `scripts/monitor.sh --watch [--config FILE] [--data-dir DIR]` | Repeat at `WATCH_INTERVAL_SECONDS` until SIGINT/SIGTERM; no invented sampling rate | 0 graceful stop; nonzero unrecoverable failure; interval excludes or includes CPU delay **must be specified in README** |
| `scripts/alerts.sh --once [--config FILE] [--data-dir DIR] [--mail-mode mock\|real\|disabled]` | Process most recent **valid and fresh** sample; persist transitions and attempts | 0 persisted/handled; 3 no/stale/invalid data; 5 delivery failed but events remain; 6 lock busy |
| `scripts/report.sh daily [--date YYYY-MM-DD] [--config FILE] [--data-dir DIR] [--output-dir DIR]` | Report prior completed local date if `--date` missing, else given explicit date | 0 valid report, including clearly labeled no-data report; 3 unrecoverable invalid dates/data; 4 I/O; 7 dep |
| `scripts/report.sh weekly [--date YYYY-MM-DD] [--config FILE] [--data-dir DIR] [--output-dir DIR]` | Report prior completed Mon–Sun week; `--date` denotes **week-start Monday** and must be validated | Same as daily; no silent partial PDF when enabled |
| `scripts/rotate_logs.sh [--as-of YYYY-MM-DD] [--config FILE] [--data-dir DIR] [--dry-run]` | Archive rows from completed days; default today's local date as boundary; dry-run prints actions only | 0 safe/no-op; nonzero on corrupt archive, lock/space/I/O/dependency |
| `scripts/setup_cron.sh --print\|--install\|--uninstall [--config FILE]` | `--print` is read-only and default; `--install`/`--uninstall` require deliberate operator action | 0 applied/printed; errors on unsafe crontab or missing tool |
| `scripts/main.sh --help\|--status\|--once\|--report daily\|--report weekly [--config FILE] [--data-dir DIR]` | A's orchestrator; `--once` calls monitor then B alerts **only after monitoring success**; reports delegate to C | Propagate meaningful nonzero; `--status` is read-only |

**Testing:** Avoid injecting fake readings through production flags. Tests supply source-fixture paths and `--data-dir` pointing to a fresh `mktemp -d` directory. Simulation never writes to the real `data/` directory. Every executable accepts `--help` displaying its actual supported syntax. CLI parsing must reject extra unexpected args.

## C5. Alert state, event history and email semantics

Persist **per-metric** severity: `cpu`, `memory`, `disk` in a stable `state.tsv`, keyed by name with last processed timestamp and severity `NORMAL|WARNING|CRITICAL`. Define formatting/atomic replace in B's tests before implementation. Events CSV proposed header:

```csv
timestamp,metric,previous_state,new_state,value,threshold,reason
```

Delivery attempts separate, e.g.:

```csv
timestamp,event_id,recipient,status,detail
```

`event_id` should be stable/recoverable (e.g. deterministic metric + sample time + state) so retry/recording cannot duplicate a transition. `detail` must be sanitized for CSV; no secret tokens or raw untrusted output. If the alert state file does not exist, treat first observed sample as transition from NORMAL (document choice), not assume an actual earlier state.

- Base levels: `>= CRITICAL` => CRITICAL; `>= WARNING` and below critical => WARNING; else NORMAL. Equality **crosses** a threshold.
- Proposed hysteresis for downward transitions: CRITICAL remains until value `< CRITICAL - H`; WARNING remains until `< WARNING - H`. When leaving CRITICAL evaluate whether WARNING or NORMAL based on the warning lower boundary. Upward escalations are immediate. Document example: warning 75, critical 90, H=2; 90 becomes CRITICAL; 89 remains CRITICAL; 87 drops to WARNING; 72 returns NORMAL. (Depending on precise inequality, at 88 remains CRITICAL; at 73 remains WARNING.)
- One alert-worthy **transition** should create one event; repeated identical level does not send again on each cron cycle. Escalation, downgrade and recovery event policies must be explicit; recommend notifying on all transitions, with low-priority recovery subject. A repeated unchanged critical condition can have optional reminder cooldown but is not required and must not introduce email storms.
- First persist event/transition atomically under alert lock; then attempt delivery, record result. **Never erase event or state due to mail failure.** If mail is retried, link to original event ID. Real sending requires verified transport and explicit human approval; tests use mock mode capturing body/subject without delivery.
- If newest row malformed, timestamp invalid, stale, missing, or CPU collector failed, **do not invent a healthy or critical state**, and do not send threshold notifications based on old samples. Return code 3 and log separate diagnostic.
- Use `mailx` meaningfully for real mail: e.g. pipe a safely formatted body to `mailx -s "$subject" -- "$recipient"` **only if the installed mailx supports that syntax**; test with local help, since variants differ. A client exit code of 0 can mean accepted by an MTA, not proven inbox receipt. Record claimed delivery scope accurately.

## C6. Report and chart semantics

- Calendar **local timezone**: daily default the complete day preceding execution; weekly default **the most recently completed Mon 00:00 through next Mon 00:00**, displayed as Mon–Sun. Example: a weekly run on Mon 2026-11-23 at 00:15 reports Mon 2026-11-16 to Sun 2026-11-22 inclusive. `--date` for weekly is that Monday, not arbitrary run date.
- Use **half-open intervals** `[start local 00:00, next local 00:00)` to avoid double count; convert timestamp offsets to instants. Explicit date validation and DST-aware boundaries (if applicable) rather than simply assuming all days are 86400 seconds.
- Collect from `data/metrics.csv` and all relevant `data/archive/metrics-*.csv.gz` without duplicate headers/rows; filter by timestamp instant/window; validate each numeric cell and timestamp. Count valid samples, invalid/skipped rows, missing data intervals and available coverage. Distinguish **0 valid samples** from **I/O/data corruption**. An informative no-data HTML report is permitted; do not invent statistics.
- For each metric report `count`, `min`, `max`, arithmetic mean (compute with `awk` as required by tech). Output one-decimal or two-decimal display precision and document it; avoid dividing by zero. Charts: timestamped CPU/RAM/disk trends via **gnuplot**, with labeled axes, legend, timezone and date window. Generate image only from sanitized numeric data, not raw executable commands.
- HTML valid enough to open in browser, escaped strings, includes start/end, timezone, count/coverage, stats, plots and warning when partial. PDF: if enabled, convert the generated report with a **verified** HTML-to-PDF or other supported path. `gnuplot` output PNG is not a PDF report by itself. If no converter, explicitly fail/report missing dependency rather than silently renaming HTML/PNG to `.pdf`.
- Generate temp files in the destination filesystem and rename to final only on success; never leave a half-written report that looks completed. Deterministic fixture + injected report date/time should yield reproducible numbers and filenames.

## C7. Rotation and retention

- Rotation boundary at midnight (after sampling from the previous day completes); archive **only complete local calendar dates**, never truncate current-day rows. Under `runtime/metrics.lock`, create durable compressed archive with header `data/archive/metrics-YYYY-MM-DD.csv.gz`, validate with `gzip -t` and count/compare rows before replacing active CSV. Prefer temporary file + atomic rename; no data loss if compression, write, or disk space fails.
- If target archive already exists, run must be **idempotent**; do not duplicate rows or blindly overwrite. Any mismatch is explicit error and preserves original data. Keep current-day rows in live CSV with exactly one header.
- Retention uses `LOG_RETENTION_DAYS` counted from `--as-of` local date; do not expire a date still needed by the prior completed weekly report or required instructor demo. **Default 30 days is a proposal**, not a rule. Retention cleanup is a separate reviewed substep; dry-run before actual deletion; never delete unexpected path or follow symlinks out of data dir. Tests run against temp fixtures, never production data.
- Consumers must continue reading archives; re-running a report after rotation should yield identical computed stats given the same input data.

## C8. Cron and runtime operations

- Proposed schedule (subject to team decision): every minute `main.sh --once`; daily at `00:10` local `report.sh daily`; Mondays `00:20` local `report.sh weekly`; daily `00:30` rotation. **Operational concern:** daily at 00:10 should include prior-day samples; rotation at 00:30 comes after report but weekly must later be reproducible from archive. WSL cron works only while its environment/service is active; if WSL stops, schedules may be missed.
- Install with a uniquely delimited **managed block** so repeating `--install` replaces only SysGuard lines, preserves unrelated crontab entries and never duplicates. `--uninstall` removes managed block **only**, ideally after preview. No auto-install in tests. Verify first `crontab -l`; an empty crontab is valid and not a reason to erase others' work.
- Set `SHELL=/bin/bash`, safe `PATH=...`, explicit `TZ`/`CRON_TZ` only where supported, and **absolute paths** based on verified repo root (never literal `~` or runtime PWD). Avoid literal `%` in cron commands (cron treats `%` specially). Direct stdout/stderr to scoped log, with rotation. Ensure overlap guards (`flock`) and no concurrent report or rotate corruption.
- `mailx` availability, MTA/SMTP routing, sender authentication, recipient, network reachability and anti-spam settings all require independent real validation. Never store passwords in Git or trigger a real send during unit tests. No claim that a service is enabled merely because its binary exists.

## C9. Versioned fixtures / expected boundaries

`tests/fixtures/v1/metrics.csv` example (illustrative, **not live**):

```csv
timestamp,cpu_percent,memory_percent,disk_percent
2026-11-20T08:00:00+05:30,74.9,50.0,40.0
2026-11-20T08:01:00+05:30,75.0,50.0,40.0
2026-11-20T08:02:00+05:30,90.0,50.0,40.0
2026-11-20T08:03:00+05:30,89.0,50.0,40.0
2026-11-20T08:04:00+05:30,87.0,50.0,40.0
2026-11-20T08:05:00+05:30,72.0,50.0,40.0
```

At CPU warning 75, critical 90, H=2, expected new event states (starting NORMAL): at 08:01 WARNING, at 08:02 CRITICAL, at 08:04 WARNING, at 08:05 NORMAL. 08:00 and 08:03 do not trigger a transition. Fixture file naming and versioning is owned by A and reviewed by B/C.

Proposed additional fixtures: `/proc/stat` counter pairs (normal, negative delta, zero delta, missing fields), `/proc/meminfo` (normal, 0 total, no available), `df -P` output (valid, missing configured mount, permission failure), invalid CSV rows, offsets around midnight, week boundaries, archived gzip files, mail mock success/failure, permissions/lock collision. **Do not** generate a production log by copying these fixtures into the actual data directory.

## C10. Acceptance gates for contract v1

The team must explicitly answer and record: exact `--date` weekly semantics; PDF required or enabled optional; mail mode and actual MTA; whether cron calls `main.sh` once per minute; default timezone; versioned fixture policy; log retention/minimum report history; whether cool-down reminders are in scope; each role's owned files; repo path and GitHub ownership; handling of malformed history; and locking technology availability. Then approve this file as `docs/CONTRACTS.md` and the agent rules **before** sending a role's implementation phase to Codex.
