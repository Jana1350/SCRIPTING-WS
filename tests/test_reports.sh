#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C TZ=Asia/Kolkata

readonly HEADER='timestamp,cpu_percent,memory_percent,disk_percent'
readonly REPORT_DATE=2026-11-20
repo_root=$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
work=$(mktemp -d /tmp/sysguard-test-reports.XXXXXXXX)
trap 'find "$work" -depth -delete' EXIT
export XDG_CACHE_HOME="$work/cache"

# A private checkout layout keeps even the default report lock and output
# paths away from the production repository.
checkout=$work/checkout
script=$checkout/scripts/report.sh
config=$checkout/html-only.conf
data=$checkout/test-data
output="$checkout/test output"
csv=$data/metrics.csv
html=$output/daily/$REPORT_DATE.html
stdout=$work/stdout
stderr=$work/stderr
mkdir -p -- "$checkout/scripts" "$checkout/config" "$data"
cp -- "$repo_root/scripts/"{report,config}.sh "$checkout/scripts/"
cp -- "$repo_root/config/defaults.conf" "$checkout/config/defaults.conf"
printf '%s\n' 'REPORT_PDF_ENABLED=0' > "$config"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    cat -- "$stdout" "$stderr" >&2
    exit 1
}

expect_status() {
    local expected=$1 category=$2 actual=0
    shift 2
    "$@" > "$stdout" 2> "$stderr" || actual=$?
    [[ $actual == "$expected" ]] || fail "expected exit $expected, got $actual ($*)"
    if [[ $category ]]; then
        grep -Fq -- "$category" "$stderr" || fail "missing diagnostic category $category"
    fi
}

assert_contains() {
    grep -Fq -- "$1" "$2" || fail "missing '$1' in $2"
}

assert_metric() {
    local metric=$1 count=$2 minimum=$3 maximum=$4 mean=$5
    assert_contains "<tr><th scope=\"row\">$metric</th><td>$count</td><td>$minimum</td><td>$maximum</td><td>$mean</td></tr>" "$html"
}

assert_no_staging() {
    local -a stages
    shopt -s nullglob
    stages=("$output/daily/".report.* "$output/weekly/".report.* "$output/charts/".chart.*)
    shopt -u nullglob
    [[ ${#stages[@]} == 0 ]] || fail 'staging files remain'
}

report() {
    bash "$script" daily --config "$config" --data-dir "$data" --output-dir "$output" "$@"
}

write_rows() {
    printf '%s\n' "$HEADER" "$@" > "$csv"
}

expect_status 0 '' bash "$script" --help
assert_contains 'Usage: report.sh daily' "$stdout"
expect_status 2 'invalid arguments' bash "$script"
expect_status 2 'invalid arguments' bash "$script" --help extra
expect_status 2 'invalid arguments' bash "$script" monthly
expect_status 2 'invalid arguments' report --unknown
expect_status 2 'invalid arguments' report --date
expect_status 2 'invalid arguments' report --date "$REPORT_DATE" --date "$REPORT_DATE"
expect_status 2 'invalid arguments' report --date "$REPORT_DATE" extra
expect_status 3 'invalid report date' report --date 2026-02-29
expect_status 3 'invalid report date' report --date 2026-11-2
expect_status 2 'configuration' bash "$script" daily --config "$work/missing.conf"
sed '/^REPORT_PDF_ENABLED=/d' "$repo_root/config/defaults.conf" > "$checkout/config/defaults.conf"
expect_status 2 'configuration' bash "$script" daily --date "$REPORT_DATE"
cp -- "$repo_root/config/defaults.conf" "$checkout/config/defaults.conf"
printf '%s\n' 'REPORT_PDF_ENABLED=2' > "$work/invalid.conf"
expect_status 2 'configuration' bash "$script" daily --config "$work/invalid.conf"
printf '%s\n' 'REPORT_PDF_ENABLED=0' 'REPORT_PDF_ENABLED=0' > "$work/invalid.conf"
expect_status 2 'configuration' bash "$script" daily --config "$work/invalid.conf"
cat > "$work/invalid.conf" <<'EOF'
REPORT_PDF_ENABLED=$(false)
EOF
expect_status 2 'configuration' bash "$script" daily --config "$work/invalid.conf"
[[ ! -e $checkout/runtime && ! -e $output ]] || fail 'invalid requests created runtime or report output'
printf '%s\n' 'PASS: help, arguments, dates, and configuration errors'

# Exercise the shared loader through the report CLI before files can be created.
config_report=(bash "$script" daily --date "$REPORT_DATE" --data-dir "$data" --output-dir "$output")
mv -- "$checkout/config/defaults.conf" "$work/shared-defaults.conf"
expect_status 2 'missing default config' "${config_report[@]}" --config "$work/shared-defaults.conf"
mv -- "$work/shared-defaults.conf" "$checkout/config/defaults.conf"
for invalid in 'CPU_WARNING=90' 'CPU_WARNING=91' 'DISK_CRITICAL=101' \
    $'CPU_WARNING=20\nALERT_HYSTERESIS_PERCENT=20' \
    $'MEMORY_WARNING=20\nALERT_HYSTERESIS_PERCENT=20' \
    $'DISK_WARNING=20\nALERT_HYSTERESIS_PERCENT=20' \
    $'CPU_WARNING=0\nALERT_HYSTERESIS_PERCENT=1' 'ALERT_HYSTERESIS_PERCENT=21' \
    'EMAIL_TO=first..last@example.test' 'MAIL_ENABLED=1' 'MAIL_ENABLED=00' 'REPORT_PDF_ENABLED=01' \
    'LOG_RETENTION_DAYS=1000000000000000000' 'UNKNOWN_SETTING=1' 'CPU_WARNING 75' $'# comment\r'; do
    printf '%s\n' "$invalid" > "$work/invalid.conf"
    expect_status 2 'configuration' "${config_report[@]}" --config "$work/invalid.conf"
done
printf 'EMAIL_TO=bad\0@example.test\n' > "$work/invalid.conf"
expect_status 2 'configuration' "${config_report[@]}" --config "$work/invalid.conf"
expect_status 2 'configuration' "${config_report[@]}" --config $'html-only.conf\n'
if (( EUID != 0 )); then
    cp -- "$config" "$work/unreadable.conf"
    chmod 000 -- "$work/unreadable.conf"
    expect_status 4 'unreadable configuration file' "${config_report[@]}" --config "$work/unreadable.conf"
    chmod 600 -- "$work/unreadable.conf"
fi
[[ ! -e $checkout/runtime && ! -e $output ]] || fail 'shared validation created runtime or report output'

# Defaults, the optional local override, and a spaced relative explicit path.
config_preview=(bash "$script" daily --date "$REPORT_DATE" --data-dir "$data" --output-dir "$work/config-reports")
config_html=$work/config-reports/daily/$REPORT_DATE.html
expect_status 0 '' "${config_preview[@]}" --config config/defaults.conf
[[ -s ${config_html%.html}.pdf ]] || fail 'shipped defaults did not enable PDF output'
printf '%s\n' REPORT_PDF_ENABLED=0 > "$checkout/config/local.conf"
expect_status 0 '' "${config_preview[@]}"
assert_contains "$checkout/config/local.conf" "$stderr"
printf '%s\n' REPORT_PDF_ENABLED=2 > "$checkout/config/local.conf"
mkdir -- "$checkout/disk fixture"
printf '%s\n' REPORT_PDF_ENABLED=0 CPU_WARNING=1 CPU_CRITICAL=100 ALERT_HYSTERESIS_PERCENT=0 \
    WATCH_INTERVAL_SECONDS=00060 LOG_RETENTION_DAYS=999999999999999999 'DISK_MOUNT=disk fixture/.' \
    > "$checkout/config/report override.conf"
expect_status 0 '' "${config_preview[@]}" --config 'config/report override.conf'
assert_contains 'Valid samples: 0' "$config_html"
[[ -s ${config_html%.html}.pdf ]] || fail 'HTML-only override removed a previous PDF'
unlink "$checkout/config/local.conf"
printf '%s\n' 'PASS: shared configuration boundaries, normalization, precedence, and validation before writes'

write_rows \
    '2026-11-20T08:00:00+05:30,20.0,50.0,60.0' \
    '2026-11-20T12:00:00+05:30,40.0,60.0,70.0' \
    '2026-11-20T18:00:00+05:30,60.0,70.0,80.0'
expect_status 0 '' report --date "$REPORT_DATE"
[[ -f $html ]] || fail 'daily HTML is missing from the expected output path'
assert_contains 'SysGuard Daily Report — 2026-11-20' "$html"
assert_contains 'Timezone: Asia/Kolkata' "$html"
assert_contains 'Valid samples: 3' "$html"
assert_contains 'Leading gap: 28800 s.' "$html"
assert_contains 'Trailing gap: 21600 s to the exclusive end.' "$html"
assert_metric CPU 3 20.0% 60.0% 40.00%
assert_metric Memory 3 50.0% 70.0% 60.00%
assert_metric Disk 3 60.0% 80.0% 70.00%
cp -- "$html" "$work/original.html"
expect_status 0 '' report --date "$REPORT_DATE"
cmp -s -- "$work/original.html" "$html" || fail 'repeated report differs from original'
before=$(sha256sum -- "$html" "$output"/charts/*.png)
expect_status 2 'configuration' "${config_report[@]}" --config $'html-only.conf\n'
[[ $(sha256sum -- "$html" "$output"/charts/*.png) == "$before" ]] ||
    fail 'invalid configuration changed the published HTML or chart'
assert_no_staging
printf '%s\n' 'PASS: 3 samples per metric; CPU min/max/mean 20/60/40, memory 50/70/60, disk 60/80/70; repeated HTML matches'

cp -- "$repo_root/tests/fixtures/v1/metrics.csv" "$csv"
expect_status 0 '' report --date "$REPORT_DATE"
assert_metric CPU 6 72.0% 90.0% 81.32%
assert_metric Memory 6 50.0% 50.0% 50.00%
assert_metric Disk 6 40.0% 40.0% 40.00%
(
    cd /
    expect_status 0 '' bash "$script" daily --config html-only.conf --data-dir test-data --date "$REPORT_DATE"
)
cmp -s -- "$html" "$checkout/reports/daily/$REPORT_DATE.html" || fail 'repository-relative paths or default report path differ'
(
    cd -- "$checkout"
    CDPATH=. expect_status 0 '' bash scripts/report.sh daily --config html-only.conf --data-dir test-data --date "$REPORT_DATE"
)
cmp -s -- "$html" "$checkout/reports/daily/$REPORT_DATE.html" || fail 'CDPATH changed repository discovery'
printf '%s\n' 'PASS: approved v1 fixture and repository-relative paths from a different working directory'
printf '%s\n' 'PASS: relative report invocation with CDPATH set'

expect_status 0 '' report --date 2026-11-19
assert_contains 'NO DATA' "$output/daily/2026-11-19.html"
rm -- "$csv"
expect_status 0 '' report --date "$REPORT_DATE"
assert_contains 'NO DATA' "$html"
assert_contains 'Valid samples: 0' "$html"
assert_contains 'Unobserved window: 86400 seconds.' "$html"
assert_metric CPU 0 N/A N/A N/A
printf '%s\n' "$HEADER" > "$csv"
expect_status 0 '' report --date "$REPORT_DATE"
assert_metric Memory 0 N/A N/A N/A
: > "$csv"
expect_status 0 '' report --date "$REPORT_DATE"
assert_metric Disk 0 N/A N/A N/A
printf '%s\n' 'PASS: missing, header-only, empty, and out-of-window inputs yield NO DATA'

printf '%s\n' 'timestamp,cpu,memory,disk' > "$csv"
cp -- "$html" "$work/last-good.html"
expect_status 3 'invalid CSV header' report --date "$REPORT_DATE"
cmp -s -- "$work/last-good.html" "$html" || fail 'bad header replaced a completed report'
write_rows \
    '2026-11-20T08:00:00+05:30,20.0,50.0,60.0' \
    '2026-11-20T08:00:00+05:30,1.0,2.0,3.0' \
    '2026-11-20T09:00:00+05:30,101.0,50.0,60.0' \
    '2026-11-20T10:00:00+05:30,20,50.0,60.0' \
    '2026-11-20T11:00:00+05:30,20.0,50.0' \
    '2026-11-20T12:00:00Z,20.0,50.0,60.0' \
    '2026-11-31T12:00:00+05:30,20.0,50.0,60.0' \
    '2026-11-20T18:00:00+05:30,60.0,70.0,80.0'
expect_status 0 'malformed or out-of-order rows' report --date "$REPORT_DATE"
assert_contains 'Skipped 6 malformed or out-of-order rows' "$html"
assert_metric CPU 2 20.0% 60.0% 40.00%
write_rows '2026-11-20T08:00:00+05:30,-1.0,50.0,60.0'
expect_status 3 'invalid CSV' report --date "$REPORT_DATE"
printf '%s\n%s' "$HEADER" '2026-11-20T08:00:00+05:30,20.0,50.0,60.0' > "$csv"
expect_status 3 'missing final newline' report --date "$REPORT_DATE"
printf '%s\n2026-11-20T08:00:00+05:30,20.0,5\0000.0,60.0\n' "$HEADER" > "$csv"
expect_status 3 'NUL byte' report --date "$REPORT_DATE"
printf '%s\n' 'PASS: bad headers, invalid rows, ordering, and truncated or binary CSV'

write_rows \
    '2026-11-20T05:29:59+05:30,1.0,2.0,3.0' \
    '2026-11-19T19:00:00-05:00,20.0,50.0,60.0' \
    '2026-11-21T05:29:59+05:30,60.0,70.0,80.0' \
    '2026-11-21T00:00:00+00:00,99.0,99.0,99.0'
TZ=UTC expect_status 0 '' report --date "$REPORT_DATE"
assert_contains '2026-11-20 00:00:00 +00:00 (inclusive)' "$html"
assert_metric CPU 2 20.0% 60.0% 40.00%
assert_contains 'Leading gap: 0 s.' "$html"
assert_contains 'Trailing gap: 1 s to the exclusive end.' "$html"
write_rows \
    '2026-03-08T00:00:00-05:00,20.0,50.0,60.0' \
    '2026-03-08T23:59:59-04:00,60.0,70.0,80.0' \
    '2026-03-09T00:00:00-04:00,99.0,99.0,99.0'
TZ=America/New_York expect_status 0 '' report --date 2026-03-08
assert_contains '2026-03-08 00:00:00 -05:00 (inclusive) to 2026-03-09 00:00:00 -04:00 (exclusive)' "$output/daily/2026-03-08.html"
assert_contains 'Valid samples: 2' "$output/daily/2026-03-08.html"
write_rows \
    '2019-09-07T23:59:59-04:00,1.0,2.0,3.0' \
    '2019-09-08T01:00:00-03:00,20.0,50.0,60.0' \
    '2019-09-09T00:00:00-03:00,99.0,99.0,99.0'
TZ=America/Santiago expect_status 0 '' report --date 2019-09-08
assert_contains '2019-09-08 01:00:00 -03:00 (inclusive)' "$output/daily/2019-09-08.html"
assert_contains 'Valid samples: 1' "$output/daily/2019-09-08.html"
write_rows '2026-11-20T08:00:00+05:30,20.0,50.0,60.0'
mkdir -- "$work/test-bin"
export SYSGUARD_TEST_REAL_DATE
SYSGUARD_TEST_REAL_DATE=$(command -v date)
cat > "$work/test-bin/date" <<'EOF'
#!/usr/bin/env bash
if [[ $# == 1 && $1 == +%F ]]; then
    printf '%s\n' "${SYSGUARD_TEST_TODAY:-2026-11-21}"
else
    exec "$SYSGUARD_TEST_REAL_DATE" "$@"
fi
EOF
chmod +x -- "$work/test-bin/date"
PATH="$work/test-bin:$PATH" expect_status 0 '' report
assert_metric CPU 1 20.0% 20.0% 20.00%
[[ ! -e $output/daily/2026-11-21.html ]] || fail 'default report used the current date'
printf '%s\n' 'PASS: date and DST boundaries, previous-day default, and leading, trailing, or empty coverage'

exec {held}>> "$data/.metrics.lock"
flock -n -x "$held"
expect_status 6 'metrics log or acquire its lock' report --date "$REPORT_DATE"
exec {held}>&-
exec {held}>> "$checkout/runtime/report.lock"
flock -n -x "$held"
expect_status 6 'report lock' report --date "$REPORT_DATE"
exec {held}>&-
mkdir -- "$checkout/data"
cp -- "$csv" "$checkout/data/metrics.csv"
ln -s -- "$checkout/data" "$checkout/data-alias"
exec {held}>> "$checkout/runtime/metrics.lock"
flock -n -x "$held"
expect_status 6 'metrics log or acquire its lock' bash "$script" daily --config "$config" \
    --data-dir "$checkout/data-alias" --output-dir "$output" --date "$REPORT_DATE"
exec {held}>&-
printf '%s\n' 'PASS: contention on default or override metrics locks and the report lock returns 6'

printf '%s\n' 'regular file' > "$work/blocked-output"
expect_status 4 'output directory' bash "$script" daily --config "$config" --data-dir "$data" \
    --output-dir "$work/blocked-output" --date "$REPORT_DATE"
cp -- "$html" "$work/last-good.html"
write_rows '2026-11-20T08:00:00+05:30,80.0,90.0,100.0'
export SYSGUARD_TEST_PUBLISH_MARKER="$work/publish-attempt"
export SYSGUARD_TEST_REAL_MV
SYSGUARD_TEST_REAL_MV=$(command -v mv)
cat > "$work/test-bin/mv" <<'EOF'
#!/usr/bin/env bash
if [[ $3 != */report.html ]]; then
    exec "$SYSGUARD_TEST_REAL_MV" "$@"
fi
if grep -Fxq '</html>' "$3"; then
    printf '%s\n' 'complete staged HTML' > "$SYSGUARD_TEST_PUBLISH_MARKER"
fi
exit 1
EOF
chmod +x -- "$work/test-bin/mv"
PATH="$work/test-bin:$PATH" expect_status 4 'could not publish' report --date "$REPORT_DATE"
rm -- "$work/test-bin/mv"
assert_contains 'complete staged HTML' "$SYSGUARD_TEST_PUBLISH_MARKER"
cmp -s -- "$work/last-good.html" "$html" || fail 'failed publication replaced a completed report'
assert_no_staging
expect_status 0 '' report --date "$REPORT_DATE"
assert_metric Disk 1 100.0% 100.0% 100.00%
assert_no_staging
printf '%s\n' 'PASS: output error and failed atomic replacement preserve the previous report and clean staging'

weekly_report() {
    bash "$script" weekly --config "$config" --data-dir "$data" --output-dir "$output" "$@"
}

write_archive() {
    local day=$1
    shift
    printf '%s\n' "$HEADER" "$@" | gzip -c > "$archive/metrics-$day.csv.gz"
}

verify_chart() {
    local report_path=$1 relative path
    relative=$(sed -n 's@.*<img src="\(\.\./charts/[^" ]*\.png\)".*@\1@p' "$report_path")
    [[ $relative ]] || fail "chart reference is missing in $report_path"
    path=${report_path%/*}/$relative
    [[ $(file -b --mime-type -- "$path") == image/png ]] || fail "chart is not a PNG: $path"
    printf '%s PNG: ' "${report_path##*/}"
    file -b -- "$path"
}

# Preserve the Phase 2 daily assertions above and exercise the resulting chart.
verify_chart "$html"
readonly WEEK_START=2026-11-16
weekly_html=$output/weekly/${WEEK_START}_to_2026-11-22.html
archive=$data/archive
mkdir -- "$archive"
write_archive 2026-11-15 \
    '2026-11-15T23:59:59+00:00,1.0,2.0,3.0' \
    '2026-11-15T19:00:00-05:00,20.0,50.0,60.0'
write_archive 2026-11-16 '2026-11-16T06:00:00+00:00,101.0,50.0,60.0'
write_archive 2026-11-22 '2026-11-23T05:29:59+05:30,60.0,70.0,80.0'
printf '%s\n' 'unrelated old archive' > "$archive/metrics-2026-01-01.csv.gz"
write_rows \
    '2026-11-16T05:30:00+05:30,20.0,50.0,60.0' \
    '2026-11-20T12:00:00+00:00,40.0,60.0,70.0' \
    '2026-11-23T00:00:00+00:00,99.0,99.0,99.0'

TZ=UTC expect_status 0 'malformed or out-of-order rows' weekly_report --date "$WEEK_START"
assert_contains 'SysGuard Weekly Report — 2026-11-16 to 2026-11-22' "$weekly_html"
assert_contains '2026-11-16 00:00:00 +00:00 (inclusive) to 2026-11-23 00:00:00 +00:00 (exclusive)' "$weekly_html"
assert_contains 'Skipped 1 malformed or out-of-order rows' "$weekly_html"
html=$weekly_html
assert_metric CPU 3 20.0% 60.0% 40.00%
assert_metric Memory 3 50.0% 70.0% 60.00%
assert_metric Disk 3 60.0% 80.0% 70.00%
verify_chart "$weekly_html"
cp -- "$weekly_html" "$work/weekly-good.html"
TZ=UTC expect_status 3 'invalid report date' weekly_report --date 2026-11-17
TZ=UTC expect_status 3 'invalid report date' weekly_report --date 2026-11-31
TZ=UTC SYSGUARD_TEST_TODAY=2026-11-23 PATH="$work/test-bin:$PATH" \
    expect_status 0 '' weekly_report
cmp -s -- "$work/weekly-good.html" "$weekly_html" || fail 'Monday default differs from explicit week'
TZ=UTC SYSGUARD_TEST_TODAY=2026-11-29 PATH="$work/test-bin:$PATH" \
    expect_status 0 '' weekly_report
cmp -s -- "$work/weekly-good.html" "$weekly_html" || fail 'Sunday default used the incomplete week'
printf '%s\n' 'PASS: weekly dates and boundaries, archived malformed row, mixed offsets, exact overlap, and repeatable charts'

# Distinct samples at the same instant in two sources are an integrity error.
write_rows '2026-11-16T05:30:00+05:30,20.1,50.0,60.0'
TZ=UTC expect_status 3 'conflicting measurements' weekly_report --date "$WEEK_START"
cmp -s -- "$work/weekly-good.html" "$weekly_html" || fail 'conflict replaced completed HTML'
printf '%s\n' 'corrupt matching archive' > "$archive/metrics-2026-11-19.csv.gz"
TZ=UTC expect_status 3 'corrupt gzip archive metrics-2026-11-19.csv.gz' weekly_report --date "$WEEK_START"
cmp -s -- "$work/weekly-good.html" "$weekly_html" || fail 'corrupt gzip replaced completed HTML'
rm -- "$archive/metrics-2026-11-19.csv.gz" "$csv"
TZ=UTC expect_status 0 '' weekly_report --date "$WEEK_START"
assert_metric CPU 2 20.0% 60.0% 40.00%
TZ=UTC expect_status 0 '' report --date "$WEEK_START"
html=$output/daily/$WEEK_START.html
assert_metric CPU 1 20.0% 20.0% 20.00%
verify_chart "$html"
write_archive 2026-12-07
TZ=UTC expect_status 0 '' weekly_report --date 2026-12-07
no_data_html=$output/weekly/2026-12-07_to_2026-12-13.html
assert_contains 'NO DATA' "$no_data_html"
if grep -Fq '<img ' "$no_data_html"; then
    fail 'no-data report unexpectedly references a chart'
fi
printf '%s\n' 'PASS: conflicts and corrupt gzip fail explicitly; archive-only and header-only periods are handled'

write_rows \
    '2026-03-02T00:00:00-05:00,20.0,50.0,60.0' \
    '2026-03-08T23:59:59-04:00,60.0,70.0,80.0' \
    '2026-03-09T00:00:00-04:00,99.0,99.0,99.0'
TZ=America/New_York expect_status 0 '' weekly_report --date 2026-03-02
assert_contains '2026-03-02 00:00:00 -05:00 (inclusive) to 2026-03-09 00:00:00 -04:00 (exclusive)' \
    "$output/weekly/2026-03-02_to_2026-03-08.html"
assert_contains 'Valid samples: 2' "$output/weekly/2026-03-02_to_2026-03-08.html"
printf '%s\n' 'PASS: weekly report uses calendar boundaries across a DST transition'

mkdir -- "$work/without-gnuplot" "$work/failing-chart" "$work/blocked-chart-output"
for utility in awk bash cat cmp date flock grep gzip mkdir mktemp mv rm rmdir sha256sum sort stat; do
    ln -s -- "$(command -v "$utility")" "$work/without-gnuplot/$utility"
done
write_rows '2026-11-20T12:00:00+00:00,40.0,60.0,70.0'
cp -- "$weekly_html" "$work/before-chart-errors.html"
TZ=UTC PATH="$work/without-gnuplot" expect_status 7 'required command unavailable: gnuplot' \
    weekly_report --date "$WEEK_START"
cmp -s -- "$work/before-chart-errors.html" "$weekly_html" || fail 'missing gnuplot replaced completed HTML'
cat > "$work/failing-chart/gnuplot" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'incomplete chart' > chart.png
exit 1
EOF
chmod +x -- "$work/failing-chart/gnuplot"
TZ=UTC PATH="$work/failing-chart:$PATH" expect_status 4 'could not generate the gnuplot chart' \
    weekly_report --date "$WEEK_START"
cmp -s -- "$work/before-chart-errors.html" "$weekly_html" || fail 'failed gnuplot replaced completed HTML'
verify_chart "$weekly_html"
printf '%s\n' 'regular file' > "$work/blocked-chart-output/charts"
TZ=UTC expect_status 4 'could not publish the chart' bash "$script" weekly --config "$config" \
    --data-dir "$data" --output-dir "$work/blocked-chart-output" --date "$WEEK_START"
[[ ! -e $work/blocked-chart-output/weekly/${weekly_html##*/} ]] || fail 'HTML published despite chart output failure'
assert_no_staging
printf '%s\n' 'PASS: missing gnuplot, chart rendering failure, and chart publication failure preserve report integrity'

pdf_report() {
    local pdf_period=$1
    shift
    bash "$script" "$pdf_period" --data-dir "$data" --output-dir "$output" "$@"
}

verify_pdf() {
    local pdf=$1 title=$2 images=$3
    [[ $(file -b --mime-type -- "$pdf") == application/pdf ]] || fail "not a PDF: $pdf"
    printf '%s: ' "${pdf##*/}"
    file -b -- "$pdf"
    pdfinfo "$pdf" > "$work/pdf-info"
    assert_contains "$title" "$work/pdf-info"
    assert_contains 'WeasyPrint' "$work/pdf-info"
    grep -E '^Pages:[[:space:]]+[1-9][0-9]*$' "$work/pdf-info" || fail 'PDF has no readable pages'
    pdfimages -list "$pdf" > "$work/pdf-images"
    awk -v expected="$images" '
        $3 == "image" && $4 == 1200 && $5 == 900 { charts++ }
        $3 == "image" { total++ }
        END { exit !(charts == expected && total == expected) }
    ' "$work/pdf-images" || fail "unexpected PDF image inventory for $pdf"
    printf 'Embedded 1200 x 900 charts: %d\n' "$images"
    pdftotext -layout "$pdf" "$work/pdf-text"
}

verify_pdf_statistics() {
    assert_contains 'Timezone: Asia/Kolkata' "$work/pdf-text"
    assert_contains 'Valid samples: 3' "$work/pdf-text"
    assert_contains 'Data quality warning.' "$work/pdf-text"
    assert_contains 'Skipped 1' "$work/pdf-text"
    grep -Eq 'CPU[[:space:]]+3[[:space:]]+20\.0%[[:space:]]+60\.0%[[:space:]]+40\.00%' "$work/pdf-text" || fail 'CPU PDF statistics differ'
    grep -Eq 'Memory[[:space:]]+3[[:space:]]+50\.0%[[:space:]]+70\.0%[[:space:]]+60\.00%' "$work/pdf-text" || fail 'memory PDF statistics differ'
    grep -Eq 'Disk[[:space:]]+3[[:space:]]+60\.0%[[:space:]]+80\.0%[[:space:]]+70\.00%' "$work/pdf-text" || fail 'disk PDF statistics differ'
}

data=$checkout/pdf-data
csv=$data/metrics.csv
output="$checkout/pdf output"
html=$output/daily/$REPORT_DATE.html
daily_pdf=${html%.html}.pdf
weekly_pdf=$output/weekly/${WEEK_START}_to_2026-11-22.pdf
pdf_config=$checkout/pdf-enabled.conf
printf '%s\n' 'REPORT_PDF_ENABLED=1' > "$pdf_config"
mkdir -- "$data" "$work/without-weasyprint"
for utility in awk bash cat cmp date file flock gnuplot grep gzip ln mkdir mktemp mv pdfimages pdfinfo rm rmdir sha256sum sort stat tail; do
    ln -s -- "$(command -v "$utility")" "$work/without-weasyprint/$utility"
done
write_rows \
    '2026-11-20T08:00:00+05:30,20.0,50.0,60.0' \
    '2026-11-20T09:00:00+05:30,101.0,50.0,60.0' \
    '2026-11-20T12:00:00+05:30,40.0,60.0,70.0' \
    '2026-11-20T18:00:00+05:30,60.0,70.0,80.0'
PATH="$work/without-weasyprint" expect_status 7 'required command unavailable: weasyprint' \
    pdf_report daily --date "$REPORT_DATE"
[[ ! -e $output ]] || fail 'missing WeasyPrint created report output'
PATH="$work/without-weasyprint" expect_status 0 '' report --date "$REPORT_DATE"
[[ -f $html && ! -e $daily_pdf ]] || fail 'HTML-only run requires WeasyPrint or left a PDF'
verify_chart "$html"
expect_status 0 '' pdf_report daily --date "$REPORT_DATE"
verify_pdf "$daily_pdf" 'SysGuard Daily Report — 2026-11-20' 1
verify_pdf_statistics
assert_contains '2026-11-21 00:00:00' "$work/pdf-text"
assert_contains 'Leading gap: 28800 s.' "$work/pdf-text"
assert_contains 'Trailing gap: 21600 s' "$work/pdf-text"
expect_status 0 '' pdf_report weekly --config "$pdf_config" --date "$WEEK_START"
verify_pdf "$weekly_pdf" 'SysGuard Weekly Report — 2026-11-16 to 2026-11-22' 1
verify_pdf_statistics
assert_contains '2026-11-23 00:00:00' "$work/pdf-text"
assert_contains 'Leading gap: 374400 s.' "$work/pdf-text"
assert_contains 'Trailing gap: 194400 s' "$work/pdf-text"
cp -- "$work/pdf-text" "$work/weekly-pdf-text"
expect_status 0 '' pdf_report weekly --config "$pdf_config" --date "$WEEK_START"
pdftotext -layout "$weekly_pdf" "$work/pdf-text"
cmp -s -- "$work/weekly-pdf-text" "$work/pdf-text" || fail 'repeated PDF has different content'
printf '%s\n' 'PASS: daily and weekly PDF content, statistics, coverage, embedded charts, and repeat generation'

mkdir -- "$checkout/empty-pdf-data"
for empty_period in daily weekly; do
    expect_status 0 '' bash "$script" "$empty_period" --config "$pdf_config" --date 2026-12-07 \
        --data-dir "$checkout/empty-pdf-data" --output-dir "$output"
    if [[ $empty_period == daily ]]; then
        verify_pdf "$output/daily/2026-12-07.pdf" 'SysGuard Daily Report — 2026-12-07' 0
        assert_contains 'Unobserved window: 86400 seconds.' "$work/pdf-text"
    else
        verify_pdf "$output/weekly/2026-12-07_to_2026-12-13.pdf" 'SysGuard Weekly Report — 2026-12-07 to 2026-12-13' 0
        assert_contains 'Unobserved window: 604800 seconds.' "$work/pdf-text"
    fi
    assert_contains 'NO DATA' "$work/pdf-text"
    assert_contains 'Valid samples: 0' "$work/pdf-text"
    assert_contains 'N/A' "$work/pdf-text"
done
printf '%s\n' 'PASS: daily and weekly NO DATA PDFs with no embedded charts'

export SYSGUARD_TEST_OLD_HTML="$work/previous.html" SYSGUARD_TEST_OLD_PDF="$work/previous.pdf"
cp -- "$html" "$SYSGUARD_TEST_OLD_HTML"
cp -- "$daily_pdf" "$SYSGUARD_TEST_OLD_PDF"
write_rows '2026-11-20T08:00:00+05:30,80.0,90.0,100.0'

assert_previous_report() {
    cmp -s -- "$SYSGUARD_TEST_OLD_HTML" "$html" || fail 'failure replaced the previous HTML'
    cmp -s -- "$SYSGUARD_TEST_OLD_PDF" "$daily_pdf" || fail 'failure replaced the previous PDF'
    assert_no_staging
}

mkdir -- "$work/snapshot-faults"
export SYSGUARD_TEST_REAL_CAT
SYSGUARD_TEST_REAL_CAT=$(command -v cat)
export SYSGUARD_TEST_SNAPSHOT_SOURCE=$csv
cat > "$work/snapshot-faults/cat" <<'EOF'
#!/usr/bin/env bash
if [[ ${2-} == "$SYSGUARD_TEST_SNAPSHOT_SOURCE" ]]; then
    case $SYSGUARD_TEST_SNAPSHOT_FAULT in
        read-error) head -n 2 -- "$2"; exit 1 ;;
        short-csv) exec head -n 2 -- "$2" ;;
        short-gzip) exec head -c 8 -- "$2" ;;
    esac
fi
exec "$SYSGUARD_TEST_REAL_CAT" "$@"
EOF
chmod +x -- "$work/snapshot-faults/cat"
write_rows '2026-11-20T08:00:00+05:30,80.0,90.0,100.0' '2026-11-20T09:00:00+05:30,81.0,91.0,99.0'
for snapshot_fault in read-error short-csv; do
    SYSGUARD_TEST_SNAPSHOT_FAULT=$snapshot_fault PATH="$work/snapshot-faults:$PATH" \
        expect_status 4 'could not verify snapshot' report --date "$REPORT_DATE"
    assert_previous_report
done
mkdir -- "$data/archive"
gzip -c -- "$csv" > "$data/archive/metrics-$REPORT_DATE.csv.gz"
SYSGUARD_TEST_SNAPSHOT_SOURCE="$data/archive/metrics-$REPORT_DATE.csv.gz" \
    SYSGUARD_TEST_SNAPSHOT_FAULT=short-gzip PATH="$work/snapshot-faults:$PATH" \
    expect_status 4 'could not verify snapshot' report --date "$REPORT_DATE"
assert_previous_report
rm -- "$data/archive/metrics-$REPORT_DATE.csv.gz"
cat > "$work/snapshot-eof" <<'EOF'
fixture_reads=0
read() {
    if [[ ${FUNCNAME[1]-} == select_samples && ${!#} == line ]]; then
        fixture_reads=$((fixture_reads + 1))
        if (( fixture_reads > 1 )); then
            printf -v line '%s' ''
            return 1
        fi
    fi
    builtin read "$@"
}
EOF
BASH_ENV="$work/snapshot-eof" expect_status 4 'incomplete CSV snapshot read' report --date "$REPORT_DATE"
assert_previous_report
printf '%s\n%s' "$HEADER" '2026-11-20T08:00:00+05:30,80.0,90.0,100.0' > "$csv"
expect_status 3 'missing final newline' report --date "$REPORT_DATE"
assert_previous_report
write_rows '2026-11-20T08:00:00+05:30,80.0,90.0,100.0'
printf '%s\n' 'PASS: copy failures, short CSV and gzip snapshots, premature EOF, and truncated rows preserve completed reports'

mkdir -- "$work/pdf-faults"
export SYSGUARD_TEST_REAL_WEASYPRINT
SYSGUARD_TEST_REAL_WEASYPRINT=$(command -v weasyprint)
export SYSGUARD_TEST_CONVERSION_ATTEMPT="$work/unsupported-attempt"
cat > "$work/pdf-faults/weasyprint" <<'EOF'
#!/usr/bin/env bash
if [[ ${!#} == --help ]]; then
    case ${SYSGUARD_TEST_CONVERTER_FAULT-} in
        rejects-option) printf '%s\n' 'unrecognized arguments: --allowed-protocols' >&2; exit 2 ;;
        old-help) printf '%s\n' '  -u BASE_URL, --base-url BASE_URL'; exit 0 ;;
        *) exec "$SYSGUARD_TEST_REAL_WEASYPRINT" "$@" ;;
    esac
fi
case ${SYSGUARD_TEST_CONVERTER_FAULT-} in
    rejects-option|old-help)
        printf '%s\n' 'conversion attempted' > "$SYSGUARD_TEST_CONVERSION_ATTEMPT"
        exit 2
        ;;
    failure)
        printf 'partial conversion\n' > "${!#}"
        exit 1
        ;;
    corrupt)
        printf '%s\n' '%PDF-1.7' 'broken PDF structure' '%%EOF' > "${!#}"
        ;;
    missing-chart)
        input=${@: -2:1}
        rm -- "${input%/*}"/charts/*.png || exit 1
        exec "$SYSGUARD_TEST_REAL_WEASYPRINT" "$@"
        ;;
    *) exec "$SYSGUARD_TEST_REAL_WEASYPRINT" "$@" ;;
esac
EOF
chmod +x -- "$work/pdf-faults/weasyprint"
for converter_fault in rejects-option old-help; do
    SYSGUARD_TEST_CONVERTER_FAULT=$converter_fault PATH="$work/pdf-faults:$PATH" \
        expect_status 7 'unsupported WeasyPrint' pdf_report daily --date "$REPORT_DATE"
    [[ ! -e $SYSGUARD_TEST_CONVERSION_ATTEMPT ]] || fail 'unsupported converter attempted to convert a report'
    assert_previous_report
done
printf '%s\n' 'PASS: incompatible converters return 7 before converting or replacing existing reports'
SYSGUARD_TEST_CONVERTER_FAULT=failure PATH="$work/pdf-faults:$PATH" \
    expect_status 4 'WeasyPrint could not convert' pdf_report daily --date "$REPORT_DATE"
assert_previous_report
SYSGUARD_TEST_CONVERTER_FAULT=corrupt PATH="$work/pdf-faults:$PATH" \
    expect_status 4 'invalid or incomplete PDF' pdf_report daily --date "$REPORT_DATE"
assert_previous_report
SYSGUARD_TEST_CONVERTER_FAULT=missing-chart PATH="$work/pdf-faults:$PATH" \
    expect_status 4 'PDF is missing the embedded gnuplot chart' pdf_report daily --date "$REPORT_DATE"
assert_previous_report
expect_status 4 'output directory' bash "$script" daily --config "$pdf_config" --date "$REPORT_DATE" \
    --data-dir "$data" --output-dir "$work/blocked-output"
assert_previous_report
printf '%s\n' 'PASS: conversion, invalid PDF, missing chart, and output directory errors preserve the previous report'

export SYSGUARD_TEST_PUBLICATION_OBSERVATION="$work/publication-observation"
cat > "$work/pdf-faults/mv" <<'EOF'
#!/usr/bin/env bash
case ${SYSGUARD_TEST_FAIL_RENAME-}:$3 in
    pdf:*/report.pdf) exit 1 ;;
    html:*/report.html)
        # Observe the real inter-rename window using only temporary reports.
        # Then return a handled error so the publisher can roll back.
        if cmp -s -- "$4" "$SYSGUARD_TEST_OLD_HTML" &&
            ! cmp -s -- "${4%.html}.pdf" "$SYSGUARD_TEST_OLD_PDF" &&
            pdfinfo "${4%.html}.pdf" > /dev/null; then
            printf '%s\n' 'old HTML and new PDF observed between renames' > "$SYSGUARD_TEST_PUBLICATION_OBSERVATION"
        fi
        exit 1
        ;;
    first-html:*/report.html) exit 1 ;;
esac
exec "$SYSGUARD_TEST_REAL_MV" "$@"
EOF
chmod +x -- "$work/pdf-faults/mv"
SYSGUARD_TEST_FAIL_RENAME=pdf PATH="$work/pdf-faults:$PATH" \
    expect_status 4 'could not publish the PDF report' pdf_report daily --date "$REPORT_DATE"
assert_previous_report
SYSGUARD_TEST_FAIL_RENAME=html PATH="$work/pdf-faults:$PATH" \
    expect_status 4 'could not publish the HTML report' pdf_report daily --date "$REPORT_DATE"
assert_contains 'old HTML and new PDF observed between renames' "$SYSGUARD_TEST_PUBLICATION_OBSERVATION"
cat -- "$SYSGUARD_TEST_PUBLICATION_OBSERVATION"
assert_previous_report
verify_chart "$html"
SYSGUARD_TEST_FAIL_RENAME=first-html PATH="$work/pdf-faults:$PATH" \
    expect_status 4 'could not publish the HTML report' bash "$script" daily --config "$pdf_config" \
    --date "$REPORT_DATE" --data-dir "$data" --output-dir "$work/first-publication"
[[ ! -e $work/first-publication/daily/$REPORT_DATE.pdf && ! -e $work/first-publication/daily/$REPORT_DATE.html ]] ||
    fail 'first failed publication left a final PDF or HTML'
PATH="$work/without-weasyprint" expect_status 0 '' report --date "$REPORT_DATE"
cmp -s -- "$SYSGUARD_TEST_OLD_PDF" "$daily_pdf" || fail 'HTML-only regeneration changed the previous PDF'
assert_contains 'Valid samples: 1' "$html"
printf '%s\n' 'PASS: PDF-first publication, rollback with and without a prior PDF, and HTML-only regeneration'
printf '%s\n' 'All daily and weekly report tests passed.'
