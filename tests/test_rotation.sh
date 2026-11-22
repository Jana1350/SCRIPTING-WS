#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C TZ=Asia/Kolkata

readonly HEADER='timestamp,cpu_percent,memory_percent,disk_percent'
readonly AS_OF=2026-11-21
readonly MONDAY='2026-11-16T00:00:00+05:30,10.0,20.0,30.0'
readonly FRIDAY_START='2026-11-19T18:30:00+00:00,20.0,30.0,40.0'
readonly FRIDAY_END='2026-11-20T18:29:59+00:00,40.0,50.0,60.0'
readonly SATURDAY='2026-11-20T18:30:00+00:00,60.0,70.0,80.0'
readonly SUNDAY='2026-11-22T09:00:00+05:30,80.0,90.0,100.0'
readonly TODAY='2026-11-23T09:00:00+05:30,22.0,33.0,44.0'

repo_root=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
work=$(mktemp -d /tmp/sysguard-test-rotation.XXXXXXXX)
trap 'find "$work" -depth -delete' EXIT
checkout=$work/checkout
script=$checkout/scripts/rotate_logs.sh
report=$checkout/scripts/report.sh
config=$checkout/test.conf
stdout=$work/stdout
stderr=$work/stderr
mkdir -p -- "$checkout/scripts" "$checkout/config" "$work/clock" "$work/faults"
cp -- "$repo_root/scripts/rotate_logs.sh" "$repo_root/scripts/report.sh" "$checkout/scripts/"
cp -- "$repo_root/config/defaults.conf" "$checkout/config/defaults.conf"
printf '%s\n' 'REPORT_PDF_ENABLED=0' 'LOG_RETENTION_DAYS=2' > "$config"

export ROTATION_TEST_DATE ROTATION_TEST_GZIP ROTATION_TEST_MKTEMP ROTATION_TEST_MV
ROTATION_TEST_DATE=$(command -v date)
ROTATION_TEST_GZIP=$(command -v gzip)
ROTATION_TEST_MKTEMP=$(command -v mktemp)
ROTATION_TEST_MV=$(command -v mv)
cat > "$work/clock/date" <<'EOF'
#!/usr/bin/env bash
if [[ $# == 1 && $1 == +%F ]]; then
    printf '%s\n' 2026-11-23
else
    exec "$ROTATION_TEST_DATE" "$@"
fi
EOF
chmod +x -- "$work/clock/date"
export PATH="$work/clock:$PATH"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    if [[ -f $stdout && -f $stderr ]]; then
        cat -- "$stdout" "$stderr" >&2
    fi
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

assert_absent() {
    [[ ! -e $1 && ! -L $1 ]] || fail "unexpected path $1"
}

new_case() {
    data=$work/cases/$1/data
    active=$data/metrics.csv
    archive=$data/archive
    mkdir -p -- "$data"
}

rotate() {
    bash "$script" --config "$config" --data-dir "$data" "$@"
}

write_csv() {
    local file=$1
    shift
    printf '%s\n' "$HEADER" "$@" > "$file"
}

write_archive() {
    local day=$1
    shift
    mkdir -p -- "$archive"
    printf '%s\n' "$HEADER" "$@" | gzip -nc > "$archive/metrics-$day.csv.gz"
}

verify_archive() {
    local day=$1 file=$archive/metrics-$1.csv.gz
    shift
    gzip -t -- "$file" || fail "gzip -t failed for $day"
    printf 'gzip -t %s: exit 0\n' "${file##*/}"
    gzip -dc -- "$file" > "$work/actual.csv"
    write_csv "$work/expected.csv" "$@"
    cmp -s -- "$work/expected.csv" "$work/actual.csv" || fail "unexpected rows in archive $day"
}

fingerprint() {
    ( cd -- "$1" && find . -printf '%y %p\n' | sort && find . -type f -exec sha256sum -- {} + | sort )
}

assert_no_staging() {
    [[ -z $(find "$data" -type d -name '.rotate.*' -print) ]] || fail 'rotation staging remains'
}

expect_status 0 '' bash "$script" --help
assert_contains 'Usage: rotate_logs.sh' "$stdout"
expect_status 2 'invalid arguments' bash "$script" --help extra
expect_status 2 'invalid arguments' bash "$script" --dry-run --dry-run
expect_status 2 'invalid arguments' bash "$script" --data-dir --dry-run
expect_status 2 'invalid arguments' bash "$script" --as-of "$AS_OF" --as-of "$AS_OF"
expect_status 3 'invalid --as-of date' bash "$script" --as-of 2026-02-29
expect_status 3 'invalid --as-of date' bash "$script" --as-of 2026-11-24
expect_status 2 'configuration' bash "$script" --config "$work/absent.conf"
printf '%s\n' 'LOG_RETENTION_DAYS=0' > "$work/invalid.conf"
expect_status 2 'configuration' bash "$script" --config "$work/invalid.conf"
assert_absent "$checkout/data"
assert_absent "$checkout/runtime"
printf '%s\n' 'PASS: CLI, date validation, and configuration failure leave no output'

new_case empty
expect_status 0 '' rotate --as-of "$AS_OF"
assert_contains 'No completed dates' "$stdout"
assert_absent "$archive"
write_csv "$active"
before=$(fingerprint "$data")
expect_status 0 '' rotate --as-of "$AS_OF"
[[ $(fingerprint "$data") == "$before" ]] || fail 'header-only log changed'
assert_no_staging
printf '%s\n' 'PASS: missing and header-only active logs are no-ops'

generate_reports() {
    local destination=$1
    bash "$report" daily --date 2026-11-20 --config "$config" --data-dir "$data" --output-dir "$destination"
    bash "$report" weekly --date 2026-11-16 --config "$config" --data-dir "$data" --output-dir "$destination"
}

assert_report_metric() {
    local html=$1 metric=$2 count=$3 min=$4 max=$5 mean=$6
    assert_contains "<tr><th scope=\"row\">$metric</th><td>$count</td><td>$min</td><td>$max</td><td>$mean</td></tr>" "$html"
}

new_case normal
write_csv "$active" "$MONDAY" "$FRIDAY_START" "$FRIDAY_END" "$SATURDAY" "$SUNDAY" "$TODAY"
before=$(fingerprint "$data")
expect_status 0 'advisory preview' rotate --as-of "$AS_OF" --dry-run
assert_contains 'Create metrics-2026-11-16.csv.gz with 1 rows.' "$stdout"
assert_contains 'Create metrics-2026-11-20.csv.gz with 2 rows.' "$stdout"
[[ $(fingerprint "$data") == "$before" ]] || fail 'lockless dry-run changed the data tree'
generate_reports "$work/before"
expect_status 0 '' rotate --as-of "$AS_OF"
verify_archive 2026-11-16 "$MONDAY"
verify_archive 2026-11-20 "$FRIDAY_START" "$FRIDAY_END"
write_csv "$work/expected.csv" "$SATURDAY" "$SUNDAY" "$TODAY"
cmp -s -- "$work/expected.csv" "$active" || fail 'cutoff/current rows or header changed'
assert_absent "$archive/metrics-2026-11-21.csv.gz"
assert_absent "$archive/metrics-2026-11-23.csv.gz"
before=$(fingerprint "$data")
archive_inode=$(stat -c %i -- "$archive/metrics-2026-11-20.csv.gz")
expect_status 0 '' rotate --as-of "$AS_OF"
[[ $(fingerprint "$data") == "$before" ]] || fail 'second rotation changed completed state'
[[ $(stat -c %i -- "$archive/metrics-2026-11-20.csv.gz") == "$archive_inode" ]] || fail 'repeated rotation rewrote the archive'
generate_reports "$work/after"
for path in daily/2026-11-20.html weekly/2026-11-16_to_2026-11-22.html; do
    cmp -s -- "$work/before/$path" "$work/after/$path" || fail "report changed after rotation: $path"
    chart=$(sed -n 's@.*<img src="../charts/\([^" ]*\.png\)".*@\1@p' "$work/after/$path")
    [[ $chart && $(file -b --mime-type -- "$work/after/charts/$chart") == image/png ]] || fail 'report chart missing'
    cmp -s -- "$work/before/charts/$chart" "$work/after/charts/$chart" || fail 'report chart changed after rotation'
done
daily=$work/after/daily/2026-11-20.html
weekly=$work/after/weekly/2026-11-16_to_2026-11-22.html
assert_report_metric "$daily" CPU 2 20.0% 40.0% 30.00%
assert_report_metric "$daily" Memory 2 30.0% 50.0% 40.00%
assert_report_metric "$daily" Disk 2 40.0% 60.0% 50.00%
assert_report_metric "$weekly" CPU 5 10.0% 80.0% 42.00%
assert_report_metric "$weekly" Memory 5 20.0% 90.0% 52.00%
assert_report_metric "$weekly" Disk 5 30.0% 100.0% 62.00%
printf '%s\n' 'PASS: local midnights, original rows, current-day preservation, and repeatability' \
    'PASS: daily/weekly counts 2/5, all min/max/mean values, and PNGs match before and after rotation'

new_case invalid
printf '%s\n%s\n' 'timestamp,cpu,memory,disk' "$FRIDAY_START" > "$active"
for defect in header range offset columns calendar order duplicate truncated nul; do
    case $defect in
        header) : ;;
        range) write_csv "$active" '2026-11-20T01:00:00+05:30,100.1,2.0,3.0' ;;
        offset) write_csv "$active" '2026-11-20T01:00:00Z,1.0,2.0,3.0' ;;
        columns) write_csv "$active" '2026-11-20T01:00:00+05:30,1.0,2.0' ;;
        calendar) write_csv "$active" '2026-11-31T01:00:00+05:30,1.0,2.0,3.0' ;;
        order) write_csv "$active" "$FRIDAY_END" "$FRIDAY_START" ;;
        duplicate) write_csv "$active" "$FRIDAY_START" '2026-11-20T00:00:00+05:30,1.0,2.0,3.0' ;;
        truncated) printf '%s\n%s' "$HEADER" "$FRIDAY_START" > "$active" ;;
        nul) printf '%s\n2026-11-20T01:00:00+05:30,1.0,2\000.0,3.0\n' "$HEADER" > "$active" ;;
    esac
    cp -- "$active" "$work/original.csv"
    expect_status 3 'invalid CSV' rotate --as-of "$AS_OF"
    cmp -s -- "$work/original.csv" "$active" || fail "rotation changed invalid active CSV: $defect"
    assert_absent "$archive"
    assert_no_staging
done
printf '%s\n' 'PASS: strict CSV validation rejects corrupt input without replacing it'

new_case matches
write_csv "$active" "$FRIDAY_START" "$FRIDAY_END" "$SATURDAY"
write_archive 2026-11-20 "$FRIDAY_START" "$FRIDAY_END"
archive_inode=$(stat -c %i -- "$archive/metrics-2026-11-20.csv.gz")
expect_status 0 '' rotate --as-of "$AS_OF"
[[ $(stat -c %i -- "$archive/metrics-2026-11-20.csv.gz") == "$archive_inode" ]] || fail 'matching archive replaced'
verify_archive 2026-11-20 "$FRIDAY_START" "$FRIDAY_END"
new_case conflict
write_csv "$active" "$MONDAY" "$FRIDAY_START" "$SATURDAY"
write_archive 2026-11-20 "$FRIDAY_END"
cp -- "$active" "$work/original.csv"
cp -- "$archive/metrics-2026-11-20.csv.gz" "$work/conflicting.gz"
expect_status 3 'does not match active rows' rotate --as-of "$AS_OF"
cmp -s -- "$work/original.csv" "$active" || fail 'conflict changed active log'
cmp -s -- "$work/conflicting.gz" "$archive/metrics-2026-11-20.csv.gz" || fail 'conflicting archive overwritten'
assert_absent "$archive/metrics-2026-11-16.csv.gz"
printf '%s\n' 'corrupt gzip' > "$archive/metrics-2026-11-20.csv.gz"
expect_status 3 'existing archive is corrupt' rotate --as-of "$AS_OF"
cmp -s -- "$work/original.csv" "$active" || fail 'corrupt archive changed active CSV'
assert_no_staging
printf '%s\n' 'PASS: matching archives are reused; mismatching or corrupt archives block publication'

new_case retention
write_csv "$active" "$FRIDAY_START" "$TODAY"
write_archive 2026-11-01 '2026-11-01T10:30:00+05:30,20.0,30.0,40.0'
write_archive 2026-11-16 "$MONDAY"
write_archive 2026-11-22 "$SUNDAY"
printf '%s\n' 'keep this file' > "$archive/notes.txt"
exec {held}>> "$data/.metrics.lock"
flock -n -x "$held"
expect_status 6 'shared metrics lock' rotate --as-of "$AS_OF"
expect_status 6 'shared metrics lock' rotate --as-of "$AS_OF" --dry-run
lock_inode=$(stat -c %i -- "$data/.metrics.lock")
exec {held}>&-
before=$(fingerprint "$data")
expect_status 0 '' rotate --dry-run
assert_contains 'before 2026-11-23' "$stdout"
assert_contains 'Retention preview: 2 completed days retained; dates from 2026-11-16' "$stdout"
assert_contains 'Retention candidate: metrics-2026-11-01.csv.gz (22 days old; confirm demo protection)' "$stdout"
[[ $(grep -c '^Retention candidate:' "$stdout") == 1 ]] || fail 'week or unexpected file included in retention candidates'
[[ $(fingerprint "$data") == "$before" ]] || fail 'retention preview made changes'
[[ $(stat -c %i -- "$data/.metrics.lock") == "$lock_inode" ]] || fail 'override lock inode changed'
case $checkout in /tmp/sysguard-test-rotation.*/checkout) ;; *) fail 'expected a private checkout' ;; esac
mkdir -p -- "$checkout/data" "$checkout/runtime"
write_csv "$checkout/data/metrics.csv" "$FRIDAY_START" "$TODAY"
exec {held}>> "$checkout/runtime/metrics.lock"
flock -n -x "$held"
expect_status 6 'shared metrics lock' bash "$script" --data-dir ./data
exec {held}>&-
expect_status 0 '' bash "$script"
write_csv "$work/expected.csv" "$TODAY"
cmp -s -- "$work/expected.csv" "$checkout/data/metrics.csv" || fail 'default cutoff archived today'
assert_absent "$checkout/data/.metrics.lock"
printf '%s\n' 'PASS: default and override lock contention, persistent inode, and retention preview without deletion'

new_case unsafe
outside=$work/outside
mkdir -- "$outside"
write_csv "$outside/metrics.csv" "$MONDAY"
printf '%s\n' 'outside sentinel' > "$outside/metrics-2026-11-20.csv.gz"
before=$(fingerprint "$outside")
ln -s -- "$outside/metrics.csv" "$active"
expect_status 4 'unsafe or unreadable active CSV' rotate --as-of "$AS_OF"
rm -- "$active"
write_csv "$active" "$FRIDAY_START" "$TODAY"
ln -s -- "$outside" "$archive"
expect_status 4 'archive directory' rotate --as-of "$AS_OF"
rm -- "$archive"
mkdir -- "$archive"
ln -s -- "$outside/metrics-2026-11-20.csv.gz" "$archive/metrics-2026-11-20.csv.gz"
expect_status 4 'unsafe archive path' rotate --as-of "$AS_OF"
expect_status 4 'unsafe archive path' rotate --as-of "$AS_OF" --dry-run
rm -- "$archive/metrics-2026-11-20.csv.gz" "$data/.metrics.lock"
ln -s -- "$outside/metrics.csv" "$data/.metrics.lock"
expect_status 4 'shared metrics lock' rotate --as-of "$AS_OF"
ln -s -- "$outside" "$work/data-link"
expect_status 4 'data directory' bash "$script" --data-dir "$work/data-link" --as-of "$AS_OF"
expect_status 4 'data directory' bash "$script" --data-dir "$work/data-link/absent" --as-of "$AS_OF"
[[ $(fingerprint "$outside") == "$before" ]] || fail 'rotation changed a symlink target outside the data directory'
assert_no_staging
printf '%s\n' 'PASS: symlink escapes through data, active CSV, archive, and lock paths are rejected'

cat > "$work/faults/gzip" <<'EOF'
#!/usr/bin/env bash
if [[ ${ROTATION_TEST_FAULT-} == gzip && $1 == -nc ]]; then
    printf '%s\n' 'partial compressed bytes'
    exit 1
fi
exec "$ROTATION_TEST_GZIP" "$@"
EOF
cat > "$work/faults/mktemp" <<'EOF'
#!/usr/bin/env bash
if [[ ${ROTATION_TEST_FAULT-} == temp && $3 == */archive/.rotate.* ]]; then
    exit 1
fi
exec "$ROTATION_TEST_MKTEMP" "$@"
EOF
cat > "$work/faults/mv" <<'EOF'
#!/usr/bin/env bash
case ${ROTATION_TEST_FAULT-}:$4 in
    archive:*/metrics-2026-11-20.csv.gz|active:*/metrics.csv) exit 1 ;;
esac
exec "$ROTATION_TEST_MV" "$@"
EOF
chmod +x -- "$work/faults/"{gzip,mktemp,mv}

for fault in gzip temp archive active; do
    new_case "failure-$fault"
    write_csv "$active" "$MONDAY" "$FRIDAY_START" "$FRIDAY_END" "$SATURDAY" "$SUNDAY" "$TODAY"
    cp -- "$active" "$work/original.csv"
    category='archive preparation failed'
    if [[ $fault == archive || $fault == active ]]; then
        category='rotation publication failed'
    fi
    ROTATION_TEST_FAULT=$fault PATH="$work/faults:$PATH" expect_status 4 "$category" rotate --as-of "$AS_OF"
    cmp -s -- "$work/original.csv" "$active" || fail "$fault failure changed the original active file"
    assert_no_staging
    case $fault in
        gzip|temp)
            assert_absent "$archive/metrics-2026-11-16.csv.gz"
            assert_absent "$archive/metrics-2026-11-20.csv.gz"
            ;;
        archive)
            verify_archive 2026-11-16 "$MONDAY"
            assert_absent "$archive/metrics-2026-11-20.csv.gz"
            ;;
        active)
            verify_archive 2026-11-16 "$MONDAY"
            verify_archive 2026-11-20 "$FRIDAY_START" "$FRIDAY_END"
            generate_reports "$work/during-recovery"
            cmp -s -- "$work/before/weekly/2026-11-16_to_2026-11-22.html" \
                "$work/during-recovery/weekly/2026-11-16_to_2026-11-22.html" || fail 'recovery overlap double-counted rows'
            ;;
    esac
    expect_status 0 '' rotate --as-of "$AS_OF"
    verify_archive 2026-11-16 "$MONDAY"
    verify_archive 2026-11-20 "$FRIDAY_START" "$FRIDAY_END"
    write_csv "$work/expected.csv" "$SATURDAY" "$SUNDAY" "$TODAY"
    cmp -s -- "$work/expected.csv" "$active" || fail "retry after $fault did not recover"
done
printf '%s\n' 'PASS: gzip, staging, and publication failures preserve active data; retries preserve history without double counting' \
    'All rotation tests passed.'
