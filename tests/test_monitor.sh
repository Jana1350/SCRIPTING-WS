#!/usr/bin/env bash

# Sensor fixtures stay in the temporary harness. The published v1 CSV is read-only.
set -euo pipefail
root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/.." && pwd -P)
source "$root/scripts/monitor.sh"
# shellcheck source=scripts/config.sh
source "$root/scripts/config.sh"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

monitor_checks=0
main_checks=0
cpu_before='cpu 100 0 100 100 0 0 0 0 1000 1000'
cpu_after='cpu 120 0 100 180 0 0 0 0 1200 1200'
memory_fixture=$'MemTotal: 1000 kB\nMemAvailable: 400 kB'
df_fixture=$'Filesystem 1024-blocks Used Available Capacity Mounted on\nfixture disk 1000 400 600 40% /'
stamp='2026-11-21T10:00:00+00:00'
disk_status=0
publish_status=0
stage_status=0
printf '%s\n' "$cpu_before" > "$work/cpu"

cat() {
    case ${1-} in
        /proc/stat) command cat -- "$work/cpu" ;;
        /proc/meminfo) printf '%s\n' "$memory_fixture" ;;
        *) command cat "$@" ;;
    esac
}

sleep_sample() {
    [[ $1 == 1 ]] || return 3
    printf '%s\n' "$cpu_after" > "$work/cpu"
}

df() {
    [[ $# == 3 && $1 == -P && $2 == -- && $3 == / ]] || return 1
    (( disk_status == 0 )) || return "$disk_status"
    printf '%s\n' "$df_fixture"
}

sample_time() {
    printf '%s\n' "$stamp"
}

mktemp() {
    (( stage_status == 0 )) || return "$stage_status"
    command mktemp "$@"
}

mv() {
    (( publish_status == 0 )) || return "$publish_status"
    command mv "$@"
}

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    if [[ -f $work/stderr ]]; then cat "$work/stderr" >&2; fi
    exit 1
}

expect_status() {
    local wanted=$1 actual=0
    shift
    printf '%s\n' "$cpu_before" > "$work/cpu"
    (monitor_main "$@") > "$work/stdout" 2> "$work/stderr" || actual=$?
    monitor_checks=$((monitor_checks + 1))
    [[ $actual == "$wanted" ]] || fail "expected exit $wanted, got $actual ($*)"
    if (( wanted != 0 )); then
        [[ ! -s $work/stdout && -s $work/stderr ]] || fail "unexpected output on failure"
    fi
}

printf '%s\n' 'DISK_MOUNT=/' > "$work/config"
run() {
    local status=$1
    shift
    expect_status "$status" --once --config "$work/config" --data-dir "$work/data" "$@"
}

csv=$work/data/metrics.csv
expected_header='timestamp,cpu_percent,memory_percent,disk_percent'
first='2026-11-21T10:00:00+00:00,20.0,60.0,40.0'
second='2026-11-21T10:00:01+00:00,20.0,60.0,40.0'
# Installations without a comma-decimal locale still exercise the forced C locale.
test_locale=$(locale -a | awk 'tolower($0) ~ /^(de|fr)_/ && !seen++ { print }')
LC_ALL=${test_locale:-C.UTF-8} run 0
[[ $(cat "$csv") == "$expected_header"$'\n'"$first" ]] || fail 'first write or rounding'
[[ $(cat "$work/stdout") == "$first" ]] || fail 'success output'
stamp='2026-11-21T10:00:01+00:00'
run 0
printf '%s\n' "$expected_header" "$first" "$second" > "$work/expected"
cmp -s "$work/expected" "$csv" || fail 'repeated once and exact header'

for stamp in '2026-11-21T11:00:01+01:00' '2026-11-21T09:59:59+00:00'; do
    run 3
    cmp -s "$work/expected" "$csv" || fail 'timestamp rejection modified CSV'
done
stamp='2026-11-21T10:00:02+00:00'

for cpu_after in "$cpu_before" 'cpu 90 0 100 100 0 0 0 0' \
    'cpu 99 0 300 180 0 0 0 0' 'cpu 1 2' 'cpu 120 0 100 x 0 0 0 0'; do
    run 3
done
[[ $(calculate_cpu_delta '0 0 0 0 0 0 0 0' '0 0 0 1 0 0 0 0') == 0.0 ]] || fail 'valid zero'
[[ $(calculate_cpu_delta '0 0 0 0 0 0 0 0' '1 0 0 0 0 0 0 0') == 100.0 ]] || fail 'valid hundred'
cpu_after='cpu 120 0 100 180 0 0 0 0'

for memory_fixture in 'MemTotal: 1000 kB' $'MemTotal: 0 kB\nMemAvailable: 0 kB' \
    $'MemTotal: 1000 kB\nMemAvailable: 1001 kB' \
    $'MemTotal: 1000 kB\nMemAvailable: 400 kB\nMemAvailable: 400 kB'; do
    run 3
done
memory_fixture=$'MemTotal: 1000 kB\nMemAvailable: 400 kB'

# Deliberately literal config input to test rejection of command substitution.
# shellcheck disable=SC2016
for bad_config in 'UNKNOWN=1' $'CPU_WARNING=80\nCPU_WARNING=81' 'CPU_WARNING=95' \
    'WATCH_INTERVAL_SECONDS=1' 'DISK_MOUNT=/missing-sysguard-test-mount' 'DISK_MOUNT=$(false)'; do
    printf '%s\n' "$bad_config" > "$work/config"
    run 2
done
printf 'DISK_MOUNT=/\0\n' > "$work/config"
run 2
printf '%s\n' 'DISK_MOUNT=/' > "$work/config"
expect_status 2 --once --config "$work/missing" --data-dir "$work/data"

df_fixture=$'Filesystem 1024-blocks Used Available Capacity Mounted on\nfixture disk 1000 400 600 40% /wrong'
run 3
df_fixture=$'Filesystem 1024-blocks Used Available Capacity Mounted on\nfixture disk 1000 400 600 40% /'
disk_status=1
run 3
expect_status 3 --watch --config "$work/config" --data-dir "$work/data"
disk_status=0

exec {held}>>"$work/data/.metrics.lock"
flock -n "$held"
run 6
cmp -s "$work/expected" "$csv" || fail 'busy one-shot writer changed CSV'
exec {held}>&-
[[ -f $work/data/.metrics.lock ]] || fail 'lock inode removed'
(
    # Redirect repository discovery so the default runtime lock stays in /tmp.
    checkout=$work/lock-checkout
    mkdir -p "$checkout"/{config,data,runtime,custom} "$work/lock-targets"
    cp "$root/config/defaults.conf" "$checkout/config/"
    # Called by the sourced monitor through expect_status.
    # shellcheck disable=SC2329
    canonical_directory() {
        case $1 in
            "$root/scripts/..") printf '%s\n' "$checkout" ;;
            /) printf '/\n' ;;
            *) return 4 ;;
        esac
    }
    printf 'unrelated\0contents\n' > "$work/lock-targets/expected"
    cp "$work/lock-targets/expected" "$work/lock-targets/file"
    default_lock=$checkout/runtime/metrics.lock
    custom_lock=$checkout/custom/.metrics.lock
    ln -s "$work/lock-targets/file" "$default_lock"
    ln -s "$work/lock-targets/file" "$custom_lock"
    cp "$work/expected" "$checkout/data/metrics.csv"
    expect_status 4 --once --config "$work/config"
    cmp "$work/expected" "$checkout/data/metrics.csv" || fail 'unsafe default lock changed CSV'
    expect_status 4 --once --data-dir custom
    expect_status 4 --watch --data-dir custom
    [[ ! -e $checkout/custom/metrics.csv ]] || fail 'unsafe custom lock published a sample'
    cmp "$work/lock-targets/expected" "$work/lock-targets/file" || fail 'lock target changed'
    mv "$default_lock" "$checkout/runtime/old-link"
    cp "$work/lock-targets/expected" "$default_lock"
    exec {held}>>"$default_lock"
    flock -n "$held"
    expect_status 6 --once --data-dir ./data
    exec {held}>&-
    expect_status 0 --once
    cmp "$work/lock-targets/expected" "$default_lock" || fail 'truncated default lock'

    mv "$checkout/runtime" "$checkout/original-runtime"
    ln -s "$work/lock-targets" "$checkout/runtime"
    expect_status 4 --once
    [[ ! -e $work/lock-targets/metrics.lock ]] || fail 'created lock through runtime symlink'
    ln -s "$work/lock-targets" "$checkout/alias"
    for dir in alias/new alias/../clean "$work/lock-targets/file/child"; do
        expect_status 4 --once --data-dir "$dir"
    done
    [[ ! -e $work/lock-targets/new ]] || fail 'created data through symlink'

    mkdir "$checkout/dangling"
    ln -s "$work/lock-targets/missing" "$checkout/dangling/.metrics.lock"
    expect_status 4 --once --data-dir dangling
    [[ ! -e $work/lock-targets/missing && ! -e $checkout/dangling/metrics.csv ]] || fail 'followed dangling lock'

    mv "$custom_lock" "$checkout/custom/old-link"
    cp "$work/lock-targets/expected" "$custom_lock"
    inode=$(stat -c '%d:%i' "$custom_lock")
    expect_status 0 --once --data-dir custom
    [[ $(stat -c '%d:%i' "$custom_lock") == "$inode" ]] || fail 'replaced regular lock'
    cmp "$work/lock-targets/expected" "$custom_lock" || fail 'truncated regular lock'
    cp "$checkout/custom/metrics.csv" "$work/before-replacement"
    # Only this isolated lock test moves the clock forward.
    # shellcheck disable=SC2030
    stamp='2026-11-21T10:00:05+00:00'
    # The descriptor stays open on the original inode while its name changes.
    flock() {
        command mv -- "$custom_lock" "$checkout/custom/previous-lock" || return 4
        cp "$work/lock-targets/expected" "$custom_lock" || return 4
        command flock "$@"
    }
    expect_status 4 --once --data-dir custom
    exec {held}>>"$custom_lock"
    command flock -n "$held"
    expect_status 4 --watch --data-dir custom
    exec {held}>&-
    cmp "$work/before-replacement" "$checkout/custom/metrics.csv" || fail 'published with mismatched lock'
)
printf '%s\n' 'PASS: unsafe default and custom locks, parent paths, persistent inode and descriptor mismatch'
(
    # Called indirectly by the sourced monitor.
    # shellcheck disable=SC2329
    flock() { return 70; }
    expect_status 4 --watch --config "$work/config" --data-dir "$work/data"
)
stage_status=1
run 4
stage_status=0
cmp -s "$work/expected" "$csv" || fail 'staging failure modified existing CSV'
publish_status=1
run 4
publish_status=0
cmp -s "$work/expected" "$csv" || fail 'publication failure modified existing CSV'
shopt -s nullglob
staged=("$work/data"/.metrics.*)
[[ ${#staged[@]} == 1 && ${staged[0]} == "$work/data/.metrics.lock" ]] || fail 'staged CSV leaked'

if (( EUID != 0 )); then
    chmod 500 "$work/data"
    run 4
    chmod 700 "$work/data"
    cmp -s "$work/expected" "$csv" || fail 'permission error modified CSV'
fi

# Pause a real writer immediately before publication. An independent lock
# probe uses the same nonblocking protocol a rotator must use.
(
    # Called indirectly by the sourced monitor in the background.
    # shellcheck disable=SC2329
    mv() {
        : > "$work/writer-ready"
        local attempt
        for ((attempt=0; attempt<250; attempt++)); do
            if [[ -f $work/publish ]]; then command mv "$@"; return; fi
            sleep 0.02
        done
        return 1
    }
    run 0
) &
writer=$!
for ((attempt=0; attempt<250; attempt++)); do
    [[ ! -e $work/writer-ready ]] || break
    sleep 0.02
done
[[ -e $work/writer-ready ]] || fail 'writer did not reach publication'
rc=0
flock -n -E 6 "$work/data/.metrics.lock" true || rc=$?
cmp -s "$csv" "$work/expected" || fail 'active file changed before publication'
: > "$work/publish"
wait "$writer" || fail 'concurrent writer failed'
[[ $rc == 6 ]] || fail "rotator lock probe returned $rc during publication"

# Reverse the roles. Use the parent clock and replace the active pathname.
# shellcheck disable=SC2031
printf '%s\n' "$stamp,20.0,60.0,40.0" >> "$work/expected"
cmp "$csv" "$work/expected" || fail 'published sample incomplete'
exec {rotator}>>"$work/data/.metrics.lock"
flock -n "$rotator"
cp "$csv" "$work/archive-expected"
command mv -- "$csv" "$work/archive"
printf '%s\n' "$expected_header" > "$csv"
stamp='2026-11-21T10:00:03+00:00'
run 6
exec {rotator}>&-
run 0
printf '%s\n' "$expected_header" "$stamp,20.0,60.0,40.0" > "$work/new-active"
cmp "$csv" "$work/new-active" || fail 'append after rotation'
cmp "$work/archive" "$work/archive-expected" || fail 'writer modified archive'
printf 'PASS: rotation lock probe exit %d, writer during rotation exit 6, retry exit 0\n' "$rc"

# Prove the agreed C9 rows are accepted by the real CSV writer.
cp "$root/tests/fixtures/v1/metrics.csv" "$csv"
run 0
{ cat "$root/tests/fixtures/v1/metrics.csv"; printf '%s\n' "$stamp,20.0,60.0,40.0"; } > "$work/expected"
cmp "$csv" "$work/expected" || fail 'v1 fixture round trip'

for invalid_csv in 'wrong header' "$CSV_HEADER"$'\n'"$second" \
    "$CSV_HEADER"$'\n''2026-11-21T10:00:01+00:00,101.0,60.0,40.0'; do
    printf '%s' "$invalid_csv" > "$csv"
    cp "$csv" "$work/rejected"
    run 3
    cmp -s "$work/rejected" "$csv" || fail 'invalid CSV was modified'
done

printf 'PASS: monitor fixtures (locale %s, permission check %s)\n' "${test_locale:-C.UTF-8}" \
    "$([[ $EUID == 0 ]] && printf skipped-root || printf exercised)"

# Hold the writer lock for two samples. Advance the monotonic clock in the
# sleep fixture so the second sample overruns two starts on a 2 s cadence.
(
    data=$work/watch
    mkdir "$data"
    printf 'WATCH_INTERVAL_SECONDS=2\n' > "$work/watch.conf"
    exec {held}>>"$data/.metrics.lock"
    flock -n "$held"
    now=0
    samples=0
    uptime_ticks() { ticks=$now; }
    sleep_sample() {
        if [[ $1 == 1 ]]; then
            samples=$((samples + 1))
            case $samples:$now in
                1:0|3:800) now=$((now + 125)) ;;
                2:200) now=$((now + 525)) ;;
                *) fail "unexpected CPU sample $samples at tick $now" ;;
            esac
            stamp="2026-11-21T10:00:0${samples}+00:00"
            printf '%s\n' "$cpu_after" > "$work/cpu"
            return
        fi
        [[ $1 == 0.75 ]] || fail "unexpected watch delay $1"
        if (( samples <= 2 )); then
            [[ ! -e $data/metrics.csv ]] || fail 'watch wrote a contended sample'
        fi
        if (( samples == 2 )); then flock -u "$held" || fail 'unlock failed'; fi
        if (( samples == 3 )); then stopping=1; fi
        now=$((now + 75))
        printf '%s\n' "$cpu_before" > "$work/cpu"
    }
    expect_status 0 --watch --config "$work/watch.conf" --data-dir "$data"
    [[ $(grep -c 'warning: metrics lock is busy, skipping this sample' "$work/stderr") == 2 ]] || fail 'watch contention warnings'
    row='2026-11-21T10:00:03+00:00,20.0,60.0,40.0'
    printf '%s\n' "$row" | cmp - "$work/stdout" || fail 'unexpected watch output'
    printf '%s\n' "$expected_header" "$row" | cmp - "$data/metrics.csv" || fail 'watch CSV after release'
)
printf '%s\n' 'PASS: watch skipped two busy samples and resumed on schedule after release'
expect_status 2 --watch --once

# Exercise orchestration against executables in a temporary checkout.
suite="$work/project with spaces"
mkdir -p "$suite/scripts" "$suite/config"
cp "$root/scripts/"{config,main,monitor}.sh "$suite/scripts/"
cp "$root/config/defaults.conf" "$suite/config/"
entry=$suite/scripts/main.sh
main_exit() {
    local wanted=$1 actual=0
    shift
    "$entry" "$@" > "$work/stdout" 2> "$work/stderr" || actual=$?
    main_checks=$((main_checks + 1))
    [[ $actual == "$wanted" ]] || fail "main $*: expected $wanted, got $actual"
    if (( wanted != 0 )); then [[ -s $work/stderr ]] || fail 'missing diagnostic'; fi
}
main_exit 0 --help
main_exit 0 --status --data-dir 'data set'
[[ ! -e "$suite/data set" ]] || fail 'status created data'
main_exit 2 --status --config missing
main_exit 2 --report monthly
main_exit 7 --report daily
main_exit 2 --mail-mode real
main_exit 2 --status --mail-mode real
main_exit 2 --report daily --mail-mode real
main_exit 2 --once --mail-mode
main_exit 2 --once --mail-mode unsupported
main_exit 2 --once --mail-mode real --mail-mode real
main_exit 7 --once --data-dir 'data set'
[[ ! -e "$suite/data set" ]] || fail 'missing alerts dependency caused writes'
export CALL_LOG=$work/calls
cat > "$suite/scripts/monitor.sh" <<'STUB'
#!/usr/bin/env bash
name=${0##*/}
printf '%s\n' "$name" "$@" >> "$CALL_LOG"
case $name in
    monitor.sh) exit "${MONITOR_RESULT:-0}" ;;
    report.sh) exit "${REPORT_RESULT:-0}" ;;
esac
STUB
cat > "$suite/scripts/alerts.sh" <<'STUB'
#!/usr/bin/env bash
alerts_once() {
    local data=$2 mode=$3
    shift 3
    [[ $mode == mock ]] || return 2
    "$@" || return "$?"
    printf '%s\n' alerts.sh --once --data-dir "$data" >> "$CALL_LOG"
    return "${ALERT_RESULT:-0}"
}
STUB
chmod +x "$suite/scripts/alerts.sh"
cp "$suite/scripts/monitor.sh" "$suite/scripts/report.sh"
rc=0
MONITOR_RESULT=3 "$entry" --once >/dev/null 2>&1 || rc=$?
[[ $rc == 3 ]] || fail 'monitor failure exit'
[[ $(cat "$CALL_LOG") == $'monitor.sh\n--once' ]] || fail 'alert invoked after failure'
: > "$CALL_LOG"
rc=0
ALERT_RESULT=5 "$entry" --once --data-dir 'data set' || rc=$?
[[ $rc == 5 ]] || fail 'delivery failure exit'
printf '%s\n' monitor.sh --once --data-dir "$suite/data set" alerts.sh --once --data-dir "$suite/data set" > "$work/expected"
cmp "$CALL_LOG" "$work/expected" || fail 'once delegation'
for period in daily weekly; do
    : > "$CALL_LOG"
    rc=0
    REPORT_RESULT=4 "$entry" --report "$period" --config 'cfg file' || rc=$?
    [[ $rc == 4 ]] || fail 'report failure exit'
    printf '%s\n' report.sh "$period" --config "$suite/cfg file" > "$work/expected"
    cmp "$CALL_LOG" "$work/expected" || fail 'report delegation'
done

# Real alerts code, a fixture collector and a fake mail client.
git init -q "$suite"
cp -- "$root/scripts/alerts.sh" "$suite/scripts/"
mail_bin=$work/mail-bin
mkdir -- "$mail_bin"
export SYSGUARD_MAIL_TEST_CAPTURE="$work/captured-mail"
export SYSGUARD_MAIL_TEST_CALLS="$work/mail-calls"
cat > "$mail_bin/mailx" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$SYSGUARD_MAIL_TEST_CALLS"
if [[ $# == 1 && $1 == --help ]]; then
    printf '%s\n' 'Usage: mailx -s subject recipient'
    exit 0
fi
[[ $# == 3 && $1 == -s && $3 == ops@example.test ]] || exit 91
printf '%s\n' "$3" >> "$SYSGUARD_MAIL_TEST_CAPTURE"
cat >> "$SYSGUARD_MAIL_TEST_CAPTURE"
exit "${MAIL_TEST_RESULT:-0}"
STUB
cat > "$suite/scripts/monitor.sh" <<'STUB'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$@" >> "$CALL_LOG"
[[ $1 == --once ]] || exit 2
shift
while (($#)); do
    case $1 in
        --config) config=$2; shift 2;;
        --data-dir) data=$2; shift 2;;
        *) exit 2;;
    esac
done
if [[ ${MAIL_TEST_WRITE_SAMPLE:-0} == 1 ]]; then
    mkdir -p -- "$data"
    printf '%s\n%s,90.0,40.0,40.0\n' 'timestamp,cpu_percent,memory_percent,disk_percent' \
        '2027-01-15T08:00:00+00:00' > "$data/metrics.csv"
fi
if [[ ${MAIL_TEST_REPLACE_CONFIG:-0} == 1 ]]; then
    printf '%s\n' MAIL_ENABLED=0 > "$config"
fi
exit "${MONITOR_RESULT:-0}"
STUB
cat > "$mail_bin/date" <<'STUB'
#!/usr/bin/env bash
if [[ $# == 1 && $1 == +%s ]]; then
    printf '%s\n' 1800000000
else
    exec /usr/bin/date "$@"
fi
STUB
chmod +x -- "$mail_bin/mailx" "$mail_bin/date"
seed_alert_data() {
    mkdir -- "$suite/$1"
    local sample_stamp
    sample_stamp=$(date -u -d '@1800000000' '+%Y-%m-%dT%H:%M:%S%:z')
    printf '%s\n%s,90.0,40.0,40.0\n' "$expected_header" "$sample_stamp" > "$suite/$1/metrics.csv"
}
# Invalid shared configurations must stop before a collector or runtime lock.
for invalid_config in 'CPU_WARNING=90' 'CPU_WARNING=91' \
    $'CPU_WARNING=20\nALERT_HYSTERESIS_PERCENT=20' 'ALERT_HYSTERESIS_PERCENT=21' \
    'EMAIL_TO=first..last@example.test' $'MAIL_ENABLED=1\nEMAIL_TO=' 'MAIL_ENABLED=1' \
    'MAIL_ENABLED=00' 'REPORT_PDF_ENABLED=01' 'LOG_RETENTION_DAYS=1000000000000000000' \
    $'CPU_WARNING=70\nCPU_WARNING=71' 'UNKNOWN=1' $'# comment\r'; do
    printf '%s\n' "$invalid_config" > "$work/invalid-shared.conf"
    expect_status 2 --once --config "$work/invalid-shared.conf" --data-dir "$suite/absent-data"
    main_exit 2 --status --config "$work/invalid-shared.conf"
    for delivery in mock real; do
        options=()
        [[ $delivery != real ]] || options+=(--mail-mode real)
        : > "$CALL_LOG"
        PATH="$mail_bin:$PATH" MAIL_TEST_WRITE_SAMPLE=1 main_exit 2 --once "${options[@]}" \
            --config "$work/invalid-shared.conf" --data-dir "$suite/absent-data"
        [[ ! -s $CALL_LOG && ! -e $suite/absent-data && ! -e $suite/runtime &&
            ! -e $SYSGUARD_MAIL_TEST_CALLS ]] || fail 'invalid configuration caused collection or runtime activity'
    done
done

# Leading zeroes are decimal, and 18 digits still fit the supported bound.
declare -A parsed=()
mkdir "$suite/disk fixture"
printf '%s\n' CPU_WARNING=0008 ALERT_HYSTERESIS_PERCENT=0 \
    LOG_RETENTION_DAYS=999999999999999999 'DISK_MOUNT=disk fixture/.' MAIL_ENABLED=0 EMAIL_TO= \
    > "$work/shared-valid.conf"
sysguard_config_load "$suite" "$work/shared-valid.conf" parsed
[[ ${parsed[CPU_WARNING]} == 8 && ${parsed[LOG_RETENTION_DAYS]} == 999999999999999999 &&
    ${parsed[DISK_MOUNT]} == "$suite/disk fixture" && ${parsed[MAIL_ENABLED]} == 0 &&
    -z ${parsed[EMAIL_TO]} ]] || fail 'shared config normalization'
main_exit 0 --status --config "$work/shared-valid.conf"
printf '%s\n' CPU_WARNING=20 ALERT_HYSTERESIS_PERCENT=19 > "$work/valid-hysteresis.conf"
main_exit 0 --status --config "$work/valid-hysteresis.conf"

# Reject output attributes that coerce values, without touching caller data.
for attributes in Ai Au Al; do
    (
        declare "-$attributes" incompatible
        incompatible[sentinel]=7
        rc=0
        sysguard_config_load "$suite" "$work/shared-valid.conf" incompatible || rc=$?
        [[ $rc == 2 && ${#incompatible[@]} == 1 && ${incompatible[sentinel]} == 7 ]]
    ) || fail "accepted or modified an output array with -$attributes"
done
declare -Ax exported_settings
sysguard_config_load "$suite" "$work/shared-valid.conf" exported_settings
[[ ${exported_settings[DISK_MOUNT]} == "$suite/disk fixture" ]] || fail 'exported associative output'

# A real filename with a trailing newline must be rejected as entered.
unsafe_config=$work/shared-valid.conf$'\n'
cp "$work/shared-valid.conf" "$unsafe_config"
expect_status 2 --once --config "$unsafe_config" --data-dir "$suite/absent-data"
main_exit 2 --status --config "$unsafe_config"
: > "$CALL_LOG"
PATH="$mail_bin:$PATH" MAIL_TEST_WRITE_SAMPLE=1 main_exit 2 --once \
    --config "$unsafe_config" --data-dir "$suite/absent-data"
[[ ! -s $CALL_LOG && ! -e $suite/absent-data && ! -e $suite/runtime ]] ||
    fail 'unsafe config path caused collection or runtime activity'

# Check the loader itself and a relative spelling of the same unsafe path.
cp "$work/shared-valid.conf" "$suite/relative.conf"$'\n'
rc=0
sysguard_config_load "$suite" $'relative.conf\n' parsed || rc=$?
[[ $rc == 2 && ${parsed[CPU_WARNING]} == 8 ]] || fail 'unsafe relative override or modified output'
main_exit 2 --status --config $'relative.conf\n'

# Physical mount resolution must preserve and reject a trailing newline.
mkdir "$suite/mount target"$'\n'
ln -s $'mount target\n' "$suite/mount-alias"
printf '%s\n' DISK_MOUNT=mount-alias > "$work/unsafe-mount.conf"
rc=0
sysguard_config_load "$suite" "$work/unsafe-mount.conf" parsed || rc=$?
[[ $rc == 2 && ${parsed[DISK_MOUNT]} == "$suite/disk fixture" ]] || fail 'unsafe physical mount path'

if (( EUID != 0 )); then
    cp "$work/shared-valid.conf" "$suite/unreadable.conf"
    chmod 000 "$suite/unreadable.conf"
    rc=0
    sysguard_config_load "$suite" unreadable.conf parsed || rc=$?
    [[ $rc == 4 && ${parsed[CPU_WARNING]} == 8 ]] || fail 'unreadable override or modified output'
    expect_status 4 --once --config "$suite/unreadable.conf" --data-dir "$suite/absent-data"
    main_exit 4 --status --config unreadable.conf
    : > "$CALL_LOG"
    for delivery in mock real; do
        options=()
        [[ $delivery != real ]] || options+=(--mail-mode real)
        PATH="$mail_bin:$PATH" MAIL_TEST_WRITE_SAMPLE=1 main_exit 4 --once "${options[@]}" \
            --config unreadable.conf --data-dir "$suite/absent-data"
    done
    [[ ! -s $CALL_LOG && ! -e $suite/absent-data && ! -e $suite/runtime ]] ||
        fail 'unreadable override caused collection or runtime activity'

    cp "$work/shared-valid.conf" "$suite/config/local.conf"
    chmod 000 "$suite/config/local.conf"
    main_exit 4 --status
    # The selected explicit override takes precedence over the unreadable local file.
    main_exit 0 --status --config "$work/shared-valid.conf"
    chmod 600 "$suite/config/local.conf"
    unlink "$suite/config/local.conf"
    chmod 600 "$suite/unreadable.conf"

    chmod 000 "$suite/config/defaults.conf"
    rc=0
    sysguard_config_load "$suite" "$work/shared-valid.conf" parsed allow-standalone || rc=$?
    [[ $rc == 4 && ${parsed[CPU_WARNING]} == 8 ]] || fail 'unreadable defaults allowed standalone fallback'
    chmod 600 "$suite/config/defaults.conf"
    # An inaccessible config directory must not trigger standalone fallback.
    chmod 600 "$suite/config"
    rc=0
    sysguard_config_load "$suite" "$work/shared-valid.conf" parsed allow-standalone || rc=$?
    chmod 700 "$suite/config"
    [[ $rc == 4 && ${parsed[CPU_WARNING]} == 8 ]] || fail 'inaccessible config directory allowed fallback'
    printf '%s\n' 'PASS: unreadable explicit, implicit and default configuration failures'
fi

mkdir "$work/standalone"
sysguard_config_load "$work/standalone" "$suite/config/defaults.conf" parsed allow-standalone
rc=0
sysguard_config_load "$work/standalone" "$work/shared-valid.conf" parsed allow-standalone || rc=$?
[[ $rc == 2 && ${parsed[CPU_WARNING]} == 75 ]] || fail 'standalone validation or preserved output'

printf '%s\n' MAIL_ENABLED=1 EMAIL_TO=ops@example.test > "$suite/config/local.conf"
printf '%s\n' MAIL_ENABLED=0 > "$work/mail-disabled.conf"
: > "$CALL_LOG"
PATH="$mail_bin:$PATH" MAIL_TEST_WRITE_SAMPLE=1 main_exit 2 --once --data-dir absent-mail \
    --mail-mode real --config "$work/mail-disabled.conf"
[[ ! -s $CALL_LOG && ! -e $suite/absent-mail && ! -e $suite/runtime && ! -e $SYSGUARD_MAIL_TEST_CALLS ]] ||
    fail 'disabled real mail created activity in a fresh checkout'
printf '%s\n' CPU_WARNING=0 ALERT_HYSTERESIS_PERCENT=0 MAIL_ENABLED=0 EMAIL_TO= > "$work/empty-recipient.conf"
PATH="$mail_bin:$PATH" MAIL_TEST_WRITE_SAMPLE=1 main_exit 0 --once --data-dir empty-recipient \
    --config "$work/empty-recipient.conf"
grep -Fq ',cpu-2027-01-15T08:00:00+00:00-CRITICAL,,captured,mock' \
    "$suite/empty-recipient/alerts/delivery.csv" || fail 'mock without a recipient or stable event ID'
[[ $(wc -l < "$suite/empty-recipient/alerts/delivery.csv") == 3 ]] || fail 'unexpected mock attempt count'
[[ ! -e $SYSGUARD_MAIL_TEST_CALLS ]] || fail 'mock invoked mailx'
printf '%s\n' 'PASS: shared validation, side-effect-free rejection and mock without a recipient'

seed_alert_data default-mail
PATH="$mail_bin:$PATH" main_exit 0 --once --data-dir default-mail
grep -Fq ',captured,mock' "$suite/default-mail/alerts/delivery.csv" || fail 'default mail mode with mail enabled'
[[ ! -e $SYSGUARD_MAIL_TEST_CALLS ]] || fail 'default mode invoked mailx'
seed_alert_data real-mail
: > "$CALL_LOG"
PATH="$mail_bin:$PATH" main_exit 0 --once --data-dir real-mail --mail-mode real
printf '%s\n' --once --data-dir "$suite/real-mail" | cmp - "$CALL_LOG" || fail 'real-mode collector arguments'
grep -Fq ',submitted,mailx_exit_zero' "$suite/real-mail/alerts/delivery.csv" || fail 'explicit real mail mode'
grep -Fq '90.0%' "$SYSGUARD_MAIL_TEST_CAPTURE" || fail 'fake mailx did not receive fixture body'
cp -- "$SYSGUARD_MAIL_TEST_CAPTURE" "$work/previous-mail"
cp -- "$SYSGUARD_MAIL_TEST_CALLS" "$work/previous-mail-calls"
seed_alert_data disabled-mail
sed -i 's/,90\.0,/,75.0,/' "$suite/disabled-mail/metrics.csv"
cp "$suite/disabled-mail/metrics.csv" "$work/previous-metrics"
: > "$CALL_LOG"
PATH="$mail_bin:$PATH" MAIL_TEST_WRITE_SAMPLE=1 main_exit 2 --once --data-dir disabled-mail --mail-mode real --config "$work/mail-disabled.conf"
grep -Fq 'real mail disabled' "$work/stderr" || fail 'missing disabled-mail diagnostic'
[[ ! -s $CALL_LOG ]] || fail 'disabled real mail invoked the collector'
cmp "$work/previous-metrics" "$suite/disabled-mail/metrics.csv" || fail 'disabled real mail changed metrics'
[[ ! -e $suite/disabled-mail/alerts ]] || fail 'disabled real mail wrote alert state'
cmp "$work/previous-mail" "$SYSGUARD_MAIL_TEST_CAPTURE" || fail 'disabled real mail invoked mailx'

real_records=("$suite/real-mail/metrics.csv" "$suite/real-mail/alerts/"{state.tsv,events.csv,delivery.csv})
records_before=$(sha256sum "${real_records[@]}")
for invalid_config in 'EMAIL_TO=.first@example.test' 'EMAIL_TO=first..last@example.test' \
    'EMAIL_TO=first.@example.test' 'EMAIL_TO=' 'EMAIL_TO=first last@example.test' \
    'CPU_WARNING=90' 'ALERT_HYSTERESIS_PERCENT=21' 'LOG_RETENTION_DAYS=0' \
    'WATCH_INTERVAL_SECONDS=1' 'MAX_DATA_AGE_SECONDS=10' 'DISK_MOUNT=/nonexistent-sysguard-mount' \
    'REPORT_PDF_ENABLED=2' 'UNRECOGNIZED=1' $'EMAIL_TO=$(false)' \
    $'CPU_WARNING=75\nCPU_WARNING=76' $'EMAIL_TO=first@example.test\r'; do
    printf '%s\n' MAIL_ENABLED=1 "$invalid_config" > "$work/invalid-mail.conf"
    PATH="$mail_bin:$PATH" MAIL_TEST_WRITE_SAMPLE=1 main_exit 2 --once --mail-mode real \
        --config "$work/invalid-mail.conf" --data-dir real-mail
    PATH="$mail_bin:$PATH" MAIL_TEST_WRITE_SAMPLE=1 main_exit 2 --once --mail-mode real \
        --config "$work/invalid-mail.conf" --data-dir absent-mail
    [[ ! -s $CALL_LOG && ! -e $suite/absent-mail ]] || fail 'invalid configuration invoked the collector'
    [[ $(sha256sum "${real_records[@]}") == "$records_before" ]] || fail 'invalid configuration changed records'
    cmp "$work/previous-mail-calls" "$SYSGUARD_MAIL_TEST_CALLS" || fail 'invalid configuration invoked mailx'
done
printf 'MAIL_ENABLED=1\nEMAIL_TO=bad\0@example.test\n' > "$work/binary-mail.conf"
for invalid_path in "$work/binary-mail.conf" "$work/missing-mail.conf" "$work/mail-disabled.conf"$'\n'; do
    PATH="$mail_bin:$PATH" MAIL_TEST_WRITE_SAMPLE=1 main_exit 2 --once --mail-mode real \
        --config "$invalid_path" --data-dir absent-mail
    [[ ! -s $CALL_LOG && ! -e $suite/absent-mail ]] || fail 'invalid configuration file invoked the collector'
    cmp "$work/previous-mail-calls" "$SYSGUARD_MAIL_TEST_CALLS" || fail 'invalid configuration file invoked mailx'
done

# A bad implicit override stops collection, while an explicit valid override wins.
printf '%s\n' MAIL_ENABLED=1 EMAIL_TO=.first@example.test > "$suite/config/local.conf"
PATH="$mail_bin:$PATH" MAIL_TEST_WRITE_SAMPLE=1 main_exit 2 --once --mail-mode real --data-dir absent-mail
[[ ! -s $CALL_LOG && ! -e $suite/absent-mail ]] || fail 'invalid local override invoked the collector'
printf '%s\n' MAIL_ENABLED=1 EMAIL_TO=ops@example.test > "$suite/valid mail.conf"
PATH="$mail_bin:$PATH" MONITOR_RESULT=3 main_exit 3 --once --mail-mode real \
    --config 'valid mail.conf' --data-dir absent-mail
cmp "$work/previous-mail-calls" "$SYSGUARD_MAIL_TEST_CALLS" || fail 'failed collection invoked mailx'
: > "$CALL_LOG"
PATH="$mail_bin:$PATH" MAIL_TEST_WRITE_SAMPLE=1 MAIL_TEST_RESULT=1 main_exit 5 --once --mail-mode real \
    --config 'valid mail.conf' --data-dir delivery-failed
printf '%s\n' --once --config "$suite/valid mail.conf" --data-dir "$suite/delivery-failed" |
    cmp - "$CALL_LOG" || fail 'wrong collector arguments in real mode'
cmp "$suite/real-mail/metrics.csv" "$suite/delivery-failed/metrics.csv" || fail 'failed delivery lost collected metrics'
grep -Fq ',cpu,NORMAL,CRITICAL,90.0,' "$suite/delivery-failed/alerts/events.csv" || fail 'failed delivery lost events'
grep -q $'cpu\t.*\tCRITICAL\t90.0' "$suite/delivery-failed/alerts/state.tsv" || fail 'failed delivery lost state'
grep -Fq ',failed,mailx_error' "$suite/delivery-failed/alerts/delivery.csv" || fail 'missing delivery failure record'

cp -- "$suite/valid mail.conf" "$suite/replace mail.conf"
PATH="$mail_bin:$PATH" MAIL_TEST_WRITE_SAMPLE=1 MAIL_TEST_REPLACE_CONFIG=1 main_exit 0 --once --mail-mode real \
    --config 'replace mail.conf' --data-dir validated-mail
grep -Fxq MAIL_ENABLED=0 "$suite/replace mail.conf" || fail 'fixture did not replace config during collection'
grep -Fq ',submitted,mailx_exit_zero' "$suite/validated-mail/alerts/delivery.csv" || fail 'alerts did not reuse validated settings'
printf '%s\n' 'PASS: mock default, real-mail preflight, runtime delivery failure and preserved metrics'

# A foreground child with normal signal dispositions receives each signal by PID.
# The sleep shim records the exact wait point and then uses exec to retain its PID.
mkdir "$work/bin"
cat > "$work/bin/sleep" <<'SLEEP'
#!/usr/bin/env bash
printf '%s %s\n' "$$" "$1" >> "$SLEEP_LOG"
exec /usr/bin/sleep "$@"
SLEEP
cat > "$work/bin/cat" <<'CAT'
#!/usr/bin/env bash
case ${1-} in
    /proc/stat)
        if [[ -s $SLEEP_LOG ]]; then
            printf 'cpu 120 0 100 180 0 0 0 0\n'
        else
            printf 'cpu 100 0 100 100 0 0 0 0\n'
        fi ;;
    /proc/meminfo) printf 'MemTotal: 1000 kB\nMemAvailable: 400 kB\n' ;;
    *) exec /usr/bin/cat "$@" ;;
esac
CAT
cat > "$work/bin/df" <<'DF'
#!/usr/bin/env bash
[[ $# == 3 && $1 == -P && $2 == -- && $3 == / ]] || exit 1
printf '%s\n' 'Filesystem 1024-blocks Used Available Capacity Mounted on' 'fixture 1000 400 600 40% /'
DF
chmod +x "$work/bin/"{sleep,cat,df}
for invocation in relative absolute; do
    (
        if [[ $invocation == relative ]]; then
            cd -- "$root"
            scripts=scripts
        else
            cd -- "$work"
            scripts=$root/scripts
        fi
        export CDPATH=. PATH="$work/bin:$PATH" SLEEP_LOG="$work/$invocation.waits"
        data=$work/$invocation
        args=(--config config/defaults.conf --data-dir "$data")
        "$scripts/monitor.sh" --once "${args[@]}" > "$work/stdout" 2> "$work/stderr" || fail "$invocation monitor invocation"
        row=$(cat "$work/stdout")
        [[ $row == *,20.0,60.0,40.0 ]] || fail "$invocation monitor output"
        printf '%s\n' "$expected_header" "$row" | cmp - "$data/metrics.csv" || fail "$invocation CSV"
        "$scripts/main.sh" --status "${args[@]}" > "$work/stdout" 2> "$work/stderr" || fail "$invocation main invocation"
        [[ $(cat "$work/stdout") == "Metrics file present: $data/metrics.csv" ]] || fail "$invocation status path"
    )
done
printf '%s\n' 'PASS: relative and absolute monitor and main invocation with CDPATH=.'

python3 - "$root" "$work" <<'PY'
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

root, work = map(Path, sys.argv[1:])
for sig, wait_count in [(signal.SIGTERM, 1), (signal.SIGINT, 2)]:
    directory = work / sig.name
    log = work / (sig.name + '.waits')
    cfg = work / (sig.name + '.conf')
    cpu_delay = 30 if wait_count == 1 else 1
    cfg.write_text(f'CPU_SAMPLE_SECONDS={cpu_delay}\nWATCH_INTERVAL_SECONDS=60\n')
    env = dict(os.environ, PATH=f'{work}/bin:' + os.environ['PATH'], SLEEP_LOG=str(log))
    with subprocess.Popen([root / 'scripts/monitor.sh', '--watch', '--config', cfg,
                           '--data-dir', directory], env=env, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, start_new_session=True) as proc:
        try:
            deadline = time.monotonic() + 8
            while not log.exists() or len(log.read_text().splitlines()) < wait_count:
                if time.monotonic() > deadline or proc.poll() is not None:
                    raise RuntimeError(f'{sig.name}: watch did not reach expected wait')
                time.sleep(.02)
            sleeper = int(log.read_text().splitlines()[-1].split()[0])
            proc.send_signal(sig)
            stdout, stderr = proc.communicate(timeout=3)
            assert proc.returncode == 0, (proc.returncode, stderr)
            assert not Path(f'/proc/{sleeper}').exists(), 'sleep child survived'
            csv = directory / 'metrics.csv'
            if wait_count == 1:
                assert not csv.exists() and not stdout
            else:
                assert stdout.endswith(b",20.0,60.0,40.0\n"), stdout
                assert len(csv.read_bytes().splitlines()) == 2
                assert csv.read_bytes().endswith(stdout) and stdout.endswith(b'\n')
                assert list(directory.glob('.metrics.*')) == [directory / '.metrics.lock']
        finally:
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
print('PASS: watch SIGTERM during sampling and SIGINT between samples')
PY
printf 'PASS: watch cadence, read-only status, dependency checks and delegation\n'

# Change a still-well-formed row in a temporary copy. No suite may start.
gate=$work/runner
mkdir -p "$gate/tests/fixtures/v1" "$gate/docs"
cp "$root/tests/run_all.sh" "$gate/tests/"
cp "$root/docs/CONTRACTS.md" "$gate/docs/"
sed 's/74\.9/75.0/' "$root/tests/fixtures/v1/metrics.csv" > "$gate/tests/fixtures/v1/metrics.csv"
# Keep the variable reference for the generated script to expand.
# shellcheck disable=SC2016
printf '%s\n' 'touch "$STARTED"' > "$gate/tests/test_monitor.sh"
rc=0
STARTED="$work/started" bash "$gate/tests/run_all.sh" > "$work/gate-log" 2>&1 || rc=$?
[[ $rc == 3 && ! -e $work/started ]] || fail "incompatible fixture gate returned $rc"
grep -Fq 'incompatible v1/metrics.csv' "$work/gate-log" || fail 'fixture mismatch diagnostic'
printf 'PASS: changed C9 row rejected before suite execution (exit %d)\n' "$rc"
printf 'Verified %d foreground monitor exit cases and %d main exit cases via helpers.\n' "$monitor_checks" "$main_checks"
