# SysGuard reporting and rotation

Member C owns the daily and weekly reports, gnuplot charts, PDF generation, and rotation. Member A collects CPU, memory, and filesystem measurements and appends them to the active metrics CSV. `report.sh` reads a consistent snapshot of that file and the relevant archives. `rotate_logs.sh` moves completed days into compressed archives that the reporter can read. Member B owns scheduling and latest-sample alerts. The [shared contract](CONTRACTS.md) defines the interfaces.

## Dependencies

| Use | Commands |
|---|---|
| Reports and rotation | Bash with associative arrays, `awk`, GNU `date` and coreutils (including `stat`), Linux procfs and `flock`, and `gzip` |
| Charts | `gnuplot` with the `pngcairo` terminal and a usable font |
| PDF generation and its runtime checks | WeasyPrint with `--allowed-protocols` support, `file`, `pdfinfo`, `pdfimages`, `grep`, `ln`, and `tail` |
| Rotation verification and flushing | `gzip -t`, `cmp`, `wc`, and GNU `sync` with file and directory arguments |
| Release checks | ShellCheck, `file`, `pdfinfo`, `pdftotext`, and `pdfimages` |

PDF generation was exercised with WeasyPrint 67.0. The converter and its PDF checks run only when PDF is enabled. The reporter checks that WeasyPrint supports `--allowed-protocols` and `--base-url`. A missing or incompatible converter exits `7` before conversion. Gnuplot is required when there are valid samples to plot.

## Commands and configuration

```text
scripts/report.sh daily  [--date YYYY-MM-DD] [--config FILE] [--data-dir DIR] [--output-dir DIR]
scripts/report.sh weekly [--date YYYY-MM-DD] [--config FILE] [--data-dir DIR] [--output-dir DIR]
scripts/report.sh today  [--config FILE] [--data-dir DIR] [--output-dir DIR]
scripts/report.sh --help
scripts/rotate_logs.sh [--as-of YYYY-MM-DD] [--config FILE] [--data-dir DIR] [--dry-run]
scripts/rotate_logs.sh --help
```

From the repository root, run the following commands for the default report periods and a read-only rotation preview.

```bash
scripts/report.sh daily
scripts/report.sh weekly
scripts/report.sh today
scripts/rotate_logs.sh --dry-run
```

Both scripts resolve relative CLI paths against the repository root. The shared `scripts/config.sh` loader requires `config/defaults.conf`. It applies an explicit `--config FILE` override when supplied or the optional `config/local.conf` otherwise. It validates the literal `KEY=value` schema, including path safety and threshold and hysteresis boundaries, before date selection or filesystem writes. See [C3](CONTRACTS.md#c3-configuration-schema-v1) for the full validation rules and exit codes. The relevant settings in the tracked defaults are:

| Setting | Default | Effect |
|---|---:|---|
| `REPORT_PDF_ENABLED` | `1` | `1` generates HTML and genuine PDF. `0` generates HTML and any chart, and leaves previously generated PDF files in place. |
| `WATCH_INTERVAL_SECONDS` | `60` | Report coverage counts gaps between valid samples that exceed this interval. |
| `LOG_RETENTION_DAYS` | `30` | Sets the age threshold for the retention preview. |

`TZ` sets the timezone for completed daily and weekly reports and rotation, with the system timezone as fallback. The current-day report always uses UTC. SysGuard V1.0 uses UTC for deployment. Verify UTC for the collector, reports, rotation, and the scheduler. CSV timestamps carry their own offsets and are converted to absolute instants before comparison. The commands use the C locale for numeric parsing.

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
| `reports/today/YYYY-MM-DD.html` and `.pdf` | Incomplete report for the named UTC date. PDF is published when enabled. |
| `reports/charts/` | Versioned PNGs referenced by report HTML. Current-day charts use `today-YYYY-MM-DD-<sha256>.png`. |

`--data-dir` replaces the `data/` root for both active and archived input. `--output-dir` replaces the `reports/` root for all report outputs. The exact CSV header is:

```csv
timestamp,cpu_percent,memory_percent,disk_percent
```

The producer writes four fields per newline-terminated row. Timestamps use a numeric offset such as `2026-11-20T08:00:00+05:30`. Percentages have one decimal place and range from `0.0` to `100.0`. Rows are strictly increasing by timestamp instant within each file.

The monitor and rotator acquire an exclusive `flock` before opening the active CSV. A real rotation initializes the data directory as needed and takes the shared metrics lock before inspecting files. The reporter takes a shared lock while copying and verifying the active and relevant archived inputs, then releases it before rendering. A held conflicting lock returns exit `6`. Keep lock files in place so the processes keep using the same inode.

## Report periods and calculations

- Daily defaults to the previous completed local date. `--date` selects a specific date.
- Weekly defaults to the latest completed Monday–Sunday. `--date` must be the first Monday. A run on Monday, November 23, 2026 defaults to November 16 through 22.
- Completed windows start at local midnight inclusive and end at the next period boundary exclusive. The conversion to instants accounts for offset and daylight-saving changes.
- `today` starts at UTC midnight inclusive and ends at a single captured current instant exclusive. This gives a partial report labeled incomplete, with no future samples. It does not accept `--date`. At UTC midnight, the window can be empty. A valid empty window publishes **NO DATA** without a chart. HTML and optional PDF remain separate from completed daily and weekly artifacts, and the scheduled jobs retain their existing periods.
- The reporter validates headers, row syntax, ranges, timestamps, and order. It combines relevant gzip archives and active data, collapses identical measurements at the same instant, and fails on differing measurements at the same instant across sources. Skipped malformed or out-of-order rows are disclosed in the report. Invalid headers, corrupt candidate gzip archives, and a damaged selection with no usable samples produce an error.
- Snapshot copies must match their sources byte for byte while the metrics lock is held. The reporter also checks that parsing reads every record from each CSV. A failed copy or incomplete read returns `4` and preserves completed reports.
- `awk` calculates count, minimum, maximum, and arithmetic mean for each metric using validated in-window samples. The mean is the sum of values divided by the sample count. The implementation accumulates integer tenths before formatting min and max to one decimal and mean to two. A valid empty window shows **NO DATA**, a count of zero, and `N/A` statistics.
- HTML and PDF show the elapsed time from the inclusive start to the first valid sample and from the last valid sample to the exclusive end. An empty window shows its full unobserved duration. These values describe sample timing. A coverage percentage would require an agreed sampling tolerance.

The reporter feeds validated epochs and numeric percentages to gnuplot to create a PNG with three panels for CPU, memory, and disk. The time axis shows UTC offsets. Plot lines break across gaps longer than the configured watch interval. HTML contains the reporting window, timezone, coverage, statistics, warnings, and a chart link. HTML, PDF, and chart files are local artifacts. When PDF is enabled, WeasyPrint renders staged HTML using local chart assets. `file` and `pdfinfo` check the output format and readable pages. `pdfimages` checks for the actual embedded chart when samples exist.

In the [terminal control center](CONTROL_CENTER.md#reports-and-archives), **6 → 1** generates today's report. **7 → 1** opens only the PDF for the current UTC date, with confirmation. If it is absent, generate today's report first. Use **7 → 4** to browse older partial reports in their folder.

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
  export LC_ALL=C TZ=Etc/UTC
  root=$(git rev-parse --show-toplevel)
  demo=$(mktemp -d /tmp/sysguard-reports-demo.XXXXXXXX)
  printf 'Fixture artifacts: %s\n' "$demo"
  export XDG_CACHE_HOME="$demo/cache"
  mkdir -p "$demo/project/scripts" "$demo/project/config" "$demo/data"
  cp "$root/scripts/"{report,rotate_logs,config}.sh "$demo/project/scripts/"
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
    shellcheck -x "$script"
  done
  bash tests/test_reports.sh
  bash tests/test_rotation.sh
  git diff --check
  git status --short --branch
)
```

The report suite covers completed periods, the UTC current-day cutoff, empty windows, offsets, CSV errors, charts, PDF content and embedded images, lock contention, and publication rollback. The rotation suite covers cutoff dates, compression and write failures, retries, lock mapping, symlink paths, and retention preview. Both use temporary fixtures.

| Exit | Meaning |
|---:|---|
| `0` | Success, including a valid no-data report or a rotation with no eligible rows. |
| `2` | Invalid CLI usage or configuration. |
| `3` | Invalid date or input, including conflicting archive data or corrupt gzip. |
| `4` | Unreadable configuration, filesystem, rendering, PDF validation, or publication failure. |
| `6` | Report or metrics lock is busy. |
| `7` | A required command is unavailable for this run. |

Failures are reported on stderr. Before retrying, check the first diagnostic and confirm the same date, config, data path, and timezone are in use.

## Integration handoff and release checks

- **Integrated interfaces.** Reports and rotation use the shared configuration loader from C3 and the monitor's metrics lock. `main.sh --report daily` and `main.sh --report weekly` forward `--config` and `--data-dir`. Call `report.sh` directly for `--date` or `--output-dir`.
- **Automated fixtures.** The report and rotation suites check the shared config at each CLI, report output, archive contents, and failure recovery in temporary checkouts.
- **Controlled renderer acceptance.** In UTC, gnuplot 6.0 patchlevel 2 and WeasyPrint 67.0 rendered a daily report from one genuine isolated monitor sample. A separate synthetic history produced daily and weekly reports with three and six samples. Both periods retained the same statistics, charts, and extracted PDF text after gzip rotation. The no-data report contained no chart. These runs used temporary data and local renderers.
- **Scheduled deployment acceptance.** Daily reports at 00:10 UTC, weekly reports on Mondays at 00:20 UTC, and archive creation at 00:30 UTC are pending actual cron evidence. Pair daemon dispatch records with completed outputs or an eligible archive and verify that the monitor continues appending. A fixture run or a scheduler preview does not establish daemon-triggered execution.

### Pull-request checklist

- [ ] Review Member C's diff against the current shared baseline and confirm the owned-file scope.
- [ ] Attach the executed test commands, exit statuses, and redacted fixture results.
- [ ] Verify the diff excludes generated reports, archives, runtime files, and local configuration.
- [ ] Record pending scheduled reporting and rotation checks, and obtain team review before merge.

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
