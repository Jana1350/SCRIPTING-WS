# SysGuard reporting and rotation

Member C owns the daily and weekly reports, gnuplot charts, PDF generation, and rotation. Member A collects CPU, memory, and filesystem measurements and appends them to the active metrics CSV. `report.sh` reads a consistent snapshot of that file and the relevant archives. `rotate_logs.sh` moves completed days into compressed archives that the reporter can read. Member B owns scheduling and latest-sample alerts. The [shared contract](CONTRACTS.md) defines the interfaces.

## Dependencies

| Use | Commands |
|---|---|
| Reports and rotation | Bash with associative arrays, `awk`, GNU `date` and coreutils, `gzip`, and Linux `flock` |
| Charts | `gnuplot` with the `pngcairo` terminal and a usable font |
| PDF generation and its runtime checks | WeasyPrint with `--allowed-protocols` support, `file`, `pdfinfo`, `pdfimages`, `grep`, `ln`, and `tail` |
| Rotation verification and flushing | `gzip -t`, `cmp`, `wc`, and GNU `sync` with file and directory arguments |
| Release checks | ShellCheck, `file`, `pdfinfo`, `pdftotext`, and `pdfimages` |

PDF generation was exercised with WeasyPrint 67.0. The converter and its PDF checks run only when PDF is enabled. Gnuplot is required when there are valid samples to plot.

## Commands and configuration

```text
scripts/report.sh daily  [--date YYYY-MM-DD] [--config FILE] [--data-dir DIR] [--output-dir DIR]
scripts/report.sh weekly [--date YYYY-MM-DD] [--config FILE] [--data-dir DIR] [--output-dir DIR]
scripts/report.sh --help
scripts/rotate_logs.sh [--as-of YYYY-MM-DD] [--config FILE] [--data-dir DIR] [--dry-run]
scripts/rotate_logs.sh --help
```

From the repository root, run the following commands for the default report periods and a read-only rotation preview.

```bash
scripts/report.sh daily
scripts/report.sh weekly
scripts/rotate_logs.sh --dry-run
```

Both scripts resolve relative CLI paths against the repository root. They read `config/defaults.conf` first, then the selected `--config FILE` or the optional `config/local.conf`. The parser accepts known `KEY=value` settings, rejects duplicate keys within a file, and validates the merged configuration before generating output. The relevant settings in the tracked defaults are:

| Setting | Default | Effect |
|---|---:|---|
| `REPORT_PDF_ENABLED` | `1` | `1` generates HTML and genuine PDF. `0` generates HTML and any chart, and leaves previously generated PDF files in place. |
| `WATCH_INTERVAL_SECONDS` | `60` | Report coverage counts gaps between valid samples that exceed this interval. |
| `LOG_RETENTION_DAYS` | `30` | Sets the age threshold for the retention preview. |

`TZ` sets the reporting and rotation timezone, with the system timezone as fallback. For a scheduled deployment, confirm the same timezone for the collector, reports, rotation, and the scheduler. CSV timestamps carry their own offsets and are converted to absolute instants before comparison. The commands use the C locale for numeric parsing.

## Data and locks

| Path relative to the repository | Purpose |
|---|---|
| `data/metrics.csv` | A appends metrics. C replaces the active file during rotation. |
| `data/archive/metrics-YYYY-MM-DD.csv.gz` | One compressed CSV with its own header per completed local date. |
| `runtime/metrics.lock` | Persistent lock for the default `data/` directory. An override resolving to the same default directory uses this lock too. |
| `<custom-data-dir>/.metrics.lock` | Persistent lock for another data directory. Use a physical directory path for rotation. |
| `runtime/report.lock` | Serializes report runs through rendering and publication. |
| `reports/daily/YYYY-MM-DD.html` and `.pdf` | Daily output named for the date represented. |
| `reports/weekly/YYYY-MM-DD_to_YYYY-MM-DD.html` and `.pdf` | Weekly output named for its inclusive Monday and Sunday dates. |
| `reports/charts/` | Versioned PNGs referenced by relative links from daily and weekly HTML. |

`--data-dir` replaces the `data/` root for both active and archived input. `--output-dir` replaces the `reports/` root for all report outputs. The exact CSV header is:

```csv
timestamp,cpu_percent,memory_percent,disk_percent
```

The producer writes four fields per newline-terminated row. Timestamps use a numeric offset such as `2026-11-20T08:00:00+05:30`. Percentages have one decimal place and range from `0.0` to `100.0`. Rows are strictly increasing by timestamp instant within each file.

The monitor and rotator acquire an exclusive `flock` before opening the active CSV. The reporter takes a shared lock while copying the active and relevant archived inputs, then releases it before rendering. A held conflicting lock returns exit `6`. Keep lock files in place so the processes keep using the same inode.

## Report periods and calculations

- Daily defaults to the previous completed local date. `--date` selects a specific date.
- Weekly defaults to the latest completed Monday–Sunday. `--date` must be the first Monday. A run on Monday, November 23, 2026 defaults to November 16 through 22.
- Every window starts at local midnight inclusive and ends at the next period boundary exclusive. The conversion to instants accounts for offset and daylight-saving changes.
- The reporter validates headers, row syntax, ranges, timestamps, and order. It combines relevant gzip archives and active data, collapses identical measurements at the same instant, and fails on differing measurements at the same instant across sources. Skipped malformed or out-of-order rows are disclosed in the report. Invalid headers, corrupt candidate gzip archives, and a damaged selection with no usable samples produce an error.
- `awk` calculates count, minimum, maximum, and arithmetic mean for each metric using validated in-window samples. The mean is the sum of values divided by the sample count. The implementation accumulates integer tenths before formatting min and max to one decimal and mean to two. A valid empty window shows **NO DATA**, a count of zero, and `N/A` statistics.

The reporter feeds validated epochs and numeric percentages to gnuplot to create a PNG with three panels for CPU, memory, and disk. The time axis shows UTC offsets. Plot lines break across gaps longer than the configured watch interval. HTML contains the reporting window, timezone, coverage, statistics, warnings, and a chart link. When PDF is enabled, WeasyPrint renders staged HTML using local chart assets. `file` and `pdfinfo` check the output format and readable pages. `pdfimages` checks for the actual embedded chart when samples exist.

## Publication, rotation, and recovery

HTML, PNG, and PDF are staged before publication. The script publishes a versioned PNG before the reports that reference it. With PDF enabled, it validates the PDF, preserves a recoverable copy of any previous PDF, replaces the PDF, then replaces the HTML. A handled HTML publication failure restores the previous PDF or removes the just-published PDF on a first run. If restoration itself fails, the diagnostic gives the retained backup path. Old chart versions remain available for existing reports.

HTML and PDF switch in **separate atomic renames**. A forced interruption between renames can leave different generations. After a failed or interrupted generation, rerun the same period with the intended PDF setting and check the resulting pair.

Rotation groups rows by their local date and archives only dates strictly earlier than `--as-of`, which defaults to today. It rejects a future cutoff. It verifies every new or reused archive with `gzip -t`, row counts, and exact decompressed content before replacing the active CSV. Each archive and the replacement CSV use staging on their respective destination filesystems. The active CSV keeps one header and all readings on or after the cutoff. A missing, empty, or header-only active file has no rows to rotate.

Archives publish before the active CSV is replaced. A failure in that interval can leave the same readings in both sources. Reports deduplicate the overlap and a retry compares the existing archives to the active rows before reusing them. Archive mismatches halt rotation and preserve the active file. Inspect the conflicting inputs with the data owner before retrying. The archive and active renames are separate operations.

`--dry-run` previews rotation and retention without writing data, archives, or locks. It can give an advisory preview when the lock file is absent. Retention is **preview-only**. The preview uses `LOG_RETENTION_DAYS` and reserves the latest completed weekly period and later dates. Candidate dates still need a demonstration-history review before any separate retention implementation.

## Isolated demo and expected results

Run this block from the repository root on or after November 21, 2026. It copies the approved v1 fixture into a temporary directory and leaves the generated artifacts there for inspection. Both the scripts and their runtime locks are isolated from the working checkout.

```bash
(
  set -euo pipefail
  export LC_ALL=C TZ=Asia/Kolkata
  root=$(git rev-parse --show-toplevel)
  demo=$(mktemp -d /tmp/sysguard-reports-demo.XXXXXXXX)
  printf 'Fixture artifacts: %s\n' "$demo"
  export XDG_CACHE_HOME="$demo/cache"
  mkdir -p "$demo/project/scripts" "$demo/project/config" "$demo/data"
  cp "$root/scripts/report.sh" "$root/scripts/rotate_logs.sh" "$demo/project/scripts/"
  cp "$root/config/defaults.conf" "$demo/project/config/"
  cp "$root/tests/fixtures/v1/metrics.csv" "$demo/data/metrics.csv"
  printf '%s\n' 'REPORT_PDF_ENABLED=1' > "$demo/pdf.conf"

  make_reports() {
    bash "$demo/project/scripts/report.sh" daily --date 2026-11-20 \
      --config "$demo/pdf.conf" --data-dir "$demo/data" --output-dir "$1"
    bash "$demo/project/scripts/report.sh" weekly --date 2026-11-16 \
      --config "$demo/pdf.conf" --data-dir "$demo/data" --output-dir "$1"
  }
  make_reports "$demo/before"
  bash "$demo/project/scripts/rotate_logs.sh" --as-of 2026-11-21 \
    --config "$demo/pdf.conf" --data-dir "$demo/data" --dry-run
  bash "$demo/project/scripts/rotate_logs.sh" --as-of 2026-11-21 \
    --config "$demo/pdf.conf" --data-dir "$demo/data"
  archive="$demo/data/archive/metrics-2026-11-20.csv.gz"
  gzip -t "$archive"
  gzip -dc "$archive" | cmp - "$root/tests/fixtures/v1/metrics.csv"
  head -n 1 "$root/tests/fixtures/v1/metrics.csv" | cmp - "$demo/data/metrics.csv"
  make_reports "$demo/after"

  for name in daily/2026-11-20 weekly/2026-11-16_to_2026-11-22; do
    cmp "$demo/before/$name.html" "$demo/after/$name.html"
    for stage in before after; do
      pdf="$demo/$stage/$name.pdf"
      file "$pdf"
      pdfinfo "$pdf" | awk '/^(Title|Producer|Pages):/'
      pdfimages -list "$pdf" | awk '$3 == "image" && $4 == 1200 && $5 == 900 { print; found = 1 } END { exit !found }'
      pdftotext -layout "$pdf" "$demo/$stage/$name.txt"
    done
    cmp "$demo/before/$name.txt" "$demo/after/$name.txt"
    grep -E 'Valid samples:|^[[:space:]]+(CPU|Memory|Disk)[[:space:]]' "$demo/after/$name.txt"
  done
  for png in "$demo/after/charts/"*.png; do
    file "$png"
    cmp "$demo/before/charts/${png##*/}" "$png"
  done
)
```

Both reports should include the same six samples before and after rotation.

| Metric | Count | Minimum | Maximum | Mean |
|---|---:|---:|---:|---:|
| CPU | 6 | 72.0% | 90.0% | 81.32% |
| Memory | 6 | 50.0% | 50.0% | 50.00% |
| Disk | 6 | 40.0% | 40.0% | 40.00% |

The Phase 6 fixture run confirmed the figures above, matching HTML and PNGs, and identical extracted PDF text before and after rotation. Each PDF had two pages and one embedded 1200 × 900 chart. The rotation suite also exercises a mixed-offset fixture with **2 daily** and **5 weekly** samples. It checks identical HTML and PNGs before and after rotation and verifies the archives and recovery overlap.

## Validation and exit codes

```bash
(
  set -e
  for script in scripts/report.sh scripts/rotate_logs.sh tests/test_reports.sh tests/test_rotation.sh; do
    bash -n "$script"
    shellcheck "$script"
  done
  bash tests/test_reports.sh
  bash tests/test_rotation.sh
  git diff --check
  git status --short --branch
)
```

The report suite covers the periods, offsets, CSV errors, charts, PDF content and embedded images, lock contention, and publication rollback. The rotation suite covers cutoff dates, compression and write failures, retries, lock mapping, symlink paths, and retention preview. Both use temporary fixtures.

| Exit | Meaning |
|---:|---|
| `0` | Success, including a valid no-data report or a rotation with no eligible rows. |
| `2` | Invalid CLI usage or configuration. |
| `3` | Invalid date or input, including conflicting archive data or corrupt gzip. |
| `4` | Filesystem, rendering, PDF validation, or publication failure. |
| `6` | Report or metrics lock is busy. |
| `7` | A required command is unavailable for this run. |

Failures are reported on stderr. Before retrying, check the first diagnostic and confirm the same date, config, data path, and timezone are in use.

## Integration handoff and release checks

- **A, monitoring and orchestration.** The locally cached `origin/feature/monitoring` ref at `8c1199c` contains `monitor.sh` and `main.sh`. Its producer header, one-decimal values, numeric timestamp offsets, and default and override lock paths match C's supported paths. The monitor acquires the lock before opening the active CSV. `main.sh --report daily|weekly` forwards `--config` and `--data-dir`. For `--date` or `--output-dir`, invoke C's `report.sh` directly. A's code is outside the Member C branch at this review.
- **A, verified delegation and follow-up.** An isolated test of the cached `main.sh` used its absolute path to generate a daily report with six fixture samples and exited `0`. A relative invocation with `CDPATH=.` exited `7` because path discovery captured extra text from `cd`. A owns the corresponding path fix. Use the absolute path for scheduled calls.
- **B, scheduling and alerts.** The current branch and local refs lack `setup_cron.sh` and `alerts.sh`. Verify the schedule preview once available. Use absolute job paths, a consistent timezone, and a `PATH` that includes the configured reporting dependencies. B needs to verify its latest-row read and missing or header-only handling while the monitor and rotator use the shared lock.
- **Integration still to run.** Verify the first monitor append after rotation leaves a header-only active file. Observed WSL sampling and scheduled execution, live alert delivery, and a clean merged release rehearsal require team review. Retention remains preview-only.

### Pull-request checklist

- [ ] Review Member C's diff against the current shared baseline and confirm the owned-file scope.
- [ ] Attach the executed test commands, exit statuses, and redacted fixture results.
- [ ] Verify the diff excludes generated reports, archives, runtime files, and local configuration.
- [ ] Record pending scheduler and alert checks, and obtain team review before merge.

### Demo checklist

- [ ] Show the fixture CSV and its expected counts and statistics.
- [ ] Open daily and weekly HTML and PDF reports and point out the chart axes and timezone.
- [ ] Preview the rotation, rotate the fixture, and show `gzip -t` and unchanged figures.
- [ ] Explain the independent publication renames and the retention preview scope.

## Member C viva prompts

| Question | Short answer |
|---|---|
| Why use a half-open date interval? | A sample at midnight belongs to exactly one period, even across changes in UTC offset. |
| Why track a count for every metric? | The count shows available measurements and is the denominator for the arithmetic mean. An empty window has no mean. |
| How does a report survive rotation? | It reads active and archived snapshots, then deduplicates equal measurements by instant. |
| Why use the same lock as the monitor? | It prevents a write or file replacement while a cooperating process reads or rotates the active CSV. |
| What does `gzip -t` prove? | It checks the compressed stream. Row counts and comparison of the decompressed contents check that the expected readings survived. |
| What proves a PDF actually includes a chart? | `file` and `pdfinfo` verify the document, `pdftotext` confirms report text, and `pdfimages` shows the embedded gnuplot image. |
| What is atomic here? | Each same-filesystem rename publishes one completed file. Separate report and archive renames have independent recovery boundaries. |
