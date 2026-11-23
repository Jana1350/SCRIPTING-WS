#!/usr/bin/env bash

# Sensor fixtures stay in the temporary harness. The published v1 CSV is read-only.
set -euo pipefail
root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/.." && pwd -P)
source "$root/scripts/monitor.sh"
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
disk_status=0

exec {held}>>"$work/data/.metrics.lock"
flock -n "$held"
run 6
expect_status 6 --watch --config "$work/config" --data-dir "$work/data"
exec {held}>&-
[[ -f $work/data/.metrics.lock ]] || fail 'lock inode removed'
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

# Reverse the roles. Replace the active pathname while holding the same inode.
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

# Drive watch's monotonic clock directly. The first sample takes 1.25 s;
# the second takes 5.25 s, overrunning two starts on a 2 s cadence.
(
    stopping=0
    ticks=0
    now=100
    cycles=0
    declare -A settings=([WATCH_INTERVAL_SECONDS]=2)
    uptime_ticks() { ticks=$now; }
    collect_once() {
        cycles=$((cycles + 1))
        if (( cycles == 1 )); then now=$((now + 125)); else now=$((now + 525)); fi
    }
    sleep_sample() {
        [[ $1 == 0.75 ]] || fail "unexpected cadence delay $1"
        now=$((now + 75))
        if (( cycles == 2 )); then stopping=1; fi
    }
    watch_loop
    [[ $cycles == 2 ]]
)
expect_status 2 --watch --once

# Exercise orchestration against executables in a temporary checkout.
suite="$work/project with spaces"
mkdir -p "$suite/scripts" "$suite/config"
cp "$root/scripts/"{main,monitor}.sh "$suite/scripts/"
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
main_exit 7 --once --data-dir 'data set'
[[ ! -e "$suite/data set" ]] || fail 'missing alerts dependency caused writes'
export CALL_LOG=$work/calls
cat > "$suite/scripts/monitor.sh" <<'STUB'
#!/usr/bin/env bash
name=${0##*/}
printf '%s\n' "$name" "$@" >> "$CALL_LOG"
case $name in
    monitor.sh) exit "${MONITOR_RESULT:-0}" ;;
    alerts.sh) exit "${ALERT_RESULT:-0}" ;;
    report.sh) exit "${REPORT_RESULT:-0}" ;;
esac
STUB
cp "$suite/scripts/monitor.sh" "$suite/scripts/alerts.sh"
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
printf '%s\n' 'touch "$STARTED"' > "$gate/tests/test_monitor.sh"
rc=0
STARTED="$work/started" bash "$gate/tests/run_all.sh" > "$work/gate-log" 2>&1 || rc=$?
[[ $rc == 3 && ! -e $work/started ]] || fail "incompatible fixture gate returned $rc"
grep -Fq 'incompatible v1/metrics.csv' "$work/gate-log" || fail 'fixture mismatch diagnostic'
printf 'PASS: changed C9 row rejected before suite execution (exit %d)\n' "$rc"
printf 'Verified %d foreground monitor exit cases and %d main exit cases via helpers.\n' "$monitor_checks" "$main_checks"
