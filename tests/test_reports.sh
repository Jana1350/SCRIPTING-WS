#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C TZ=Asia/Kolkata

readonly HEADER='timestamp,cpu_percent,memory_percent,disk_percent'
readonly REPORT_DATE=2026-11-20
repo_root=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
work=$(mktemp -d /tmp/sysguard-test-reports.XXXXXXXX)
trap 'find "$work" -depth -delete' EXIT

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
cp -- "$repo_root/scripts/report.sh" "$script"
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
    stages=("$output/daily/".report.*)
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
expect_status 2 'invalid arguments' bash "$script" weekly
expect_status 2 'invalid arguments' report --unknown
expect_status 2 'invalid arguments' report --date
expect_status 2 'invalid arguments' report --date "$REPORT_DATE" --date "$REPORT_DATE"
expect_status 2 'invalid arguments' report --date "$REPORT_DATE" extra
expect_status 3 'invalid report date' report --date 2026-02-29
expect_status 3 'invalid report date' report --date 2026-11-2
expect_status 2 'configuration' bash "$script" daily --config "$work/missing.conf"
expect_status 7 'PDF generation is unavailable' bash "$script" daily --data-dir "$data" --output-dir "$output"
printf '%s\n' 'REPORT_PDF_ENABLED=0' 'REPORT_PDF_ENABLED=0' > "$work/invalid.conf"
expect_status 2 'configuration' bash "$script" daily --config "$work/invalid.conf"
cat > "$work/invalid.conf" <<'EOF'
REPORT_PDF_ENABLED=$(false)
EOF
expect_status 2 'configuration' bash "$script" daily --config "$work/invalid.conf"
[[ ! -e $checkout/runtime && ! -e $output ]] || fail 'invalid requests created runtime or report output'
printf '%s\n' 'PASS: help, arguments, dates, and configuration errors'

write_rows \
    '2026-11-20T08:00:00+05:30,20.0,50.0,60.0' \
    '2026-11-20T12:00:00+05:30,40.0,60.0,70.0' \
    '2026-11-20T18:00:00+05:30,60.0,70.0,80.0'
expect_status 0 '' report --date "$REPORT_DATE"
[[ -f $html ]] || fail 'daily HTML is missing from the expected output path'
assert_contains 'SysGuard Daily Report — 2026-11-20' "$html"
assert_contains 'Timezone: Asia/Kolkata' "$html"
assert_contains 'Valid samples: 3' "$html"
assert_metric CPU 3 20.0% 60.0% 40.00%
assert_metric Memory 3 50.0% 70.0% 60.00%
assert_metric Disk 3 60.0% 80.0% 70.00%
cp -- "$html" "$work/original.html"
expect_status 0 '' report --date "$REPORT_DATE"
cmp -s -- "$work/original.html" "$html" || fail 'repeated report differs from original'
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
printf '%s\n' 'PASS: approved v1 fixture and repository-relative paths from a different working directory'

expect_status 0 '' report --date 2026-11-19
assert_contains 'NO DATA' "$output/daily/2026-11-19.html"
rm -- "$csv"
expect_status 0 '' report --date "$REPORT_DATE"
assert_contains 'NO DATA' "$html"
assert_contains 'Valid samples: 0' "$html"
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
    printf '%s\n' 2026-11-21
else
    exec "$SYSGUARD_TEST_REAL_DATE" "$@"
fi
EOF
chmod +x -- "$work/test-bin/date"
PATH="$work/test-bin:$PATH" expect_status 0 '' report
assert_metric CPU 1 20.0% 20.0% 20.00%
[[ ! -e $output/daily/2026-11-21.html ]] || fail 'default report used the current date'
printf '%s\n' 'PASS: inclusive start, exclusive end, mixed offsets, DST, and previous local day default'

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
cat > "$work/test-bin/mv" <<'EOF'
#!/usr/bin/env bash
if grep -Fxq '</html>' "$3"; then
    printf '%s\n' 'complete staged HTML' > "$SYSGUARD_TEST_PUBLISH_MARKER"
fi
exit 1
EOF
chmod +x -- "$work/test-bin/mv"
PATH="$work/test-bin:$PATH" expect_status 4 'could not publish' report --date "$REPORT_DATE"
assert_contains 'complete staged HTML' "$SYSGUARD_TEST_PUBLISH_MARKER"
cmp -s -- "$work/last-good.html" "$html" || fail 'failed publication replaced a completed report'
assert_no_staging
expect_status 0 '' report --date "$REPORT_DATE"
assert_metric Disk 1 100.0% 100.0% 100.00%
assert_no_staging
printf '%s\n' 'PASS: output error and failed atomic replacement preserve the previous report and clean staging'
printf '%s\n' 'All daily HTML report tests passed.'
