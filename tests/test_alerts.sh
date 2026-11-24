#!/usr/bin/env bash
set -euo pipefail
# Both suites copy the real entry points into an isolated temporary checkout.
sandbox() {
    local source
    source=$(cd "$(dirname -- "${BASH_SOURCE[0]}")/../scripts" && pwd -P)
    temp=$(mktemp -d)
    trap 'rm -rf -- "$temp"' EXIT
    repo="$temp/SysGuard user's checkout"
    git init -q "$repo"
    mkdir -p "$repo/scripts" "$repo/config" "$temp/bin" "$temp/data"
    cp "$source/alerts.sh" "$source/setup_cron.sh" "$repo/scripts/"
    cat > "$repo/config/defaults.conf" <<'CONF'
CPU_WARNING=75
CPU_CRITICAL=90
MEMORY_WARNING=75
MEMORY_CRITICAL=90
DISK_WARNING=80
DISK_CRITICAL=95
ALERT_HYSTERESIS_PERCENT=2
CPU_SAMPLE_SECONDS=1
WATCH_INTERVAL_SECONDS=60
MAX_DATA_AGE_SECONDS=180
LOG_RETENTION_DAYS=30
MAIL_ENABLED=0
EMAIL_TO=ops@example.test
DISK_MOUNT=/
REPORT_PDF_ENABLED=0
CONF
    export PATH="$temp/bin:$PATH"
}
expect() {
    local expected=$1 rc=0
    shift
    "$@" > "$temp/stdout" 2>"$temp/stderr" || rc=$?
    if [[ $rc != "$expected" ]]; then
        cat "$temp/stderr" >&2
        printf 'expected %s, got %s for %s\n' "$expected" "$rc" "$*" >&2; exit 1
    fi
}
freeze_clock() {
    # Freeze only the current time; parse actual timestamps using GNU date.
    cat > "$temp/bin/date" <<'CLOCK'
#!/usr/bin/env bash
if [[ $# == 1 && $1 == +%s ]]; then echo 1800000000; else exec /usr/bin/date "$@"; fi
CLOCK
    chmod +x "$temp/bin/date"
}
test_locks() (
    sandbox
    freeze_clock
    local data lock path inode before label
    local -a cmd
    local alerts=$repo/scripts/alerts.sh alert_lock=$repo/runtime/alerts.lock
    printf 'preserve these lock bytes\0\n' > "$temp/bytes"
    for label in default explicit-default custom; do
        cmd=("$alerts" --once --mail-mode mock)
        case $label in
            default) data=$repo/data; lock=$repo/runtime/metrics.lock;;
            explicit-default) cmd+=(--data-dir ./data/.);;
            custom) data=$temp/custom; lock=$data/.metrics.lock; cmd+=(--data-dir "$data");;
        esac
        mkdir -p -- "$data"
        local records=("$data/alerts/"{state.tsv,events.csv,delivery.csv,mock-mail.log})
        local header=timestamp,cpu_percent,memory_percent,disk_percent stamp
        stamp=$(date -u -d '@1799999940' '+%Y-%m-%dT%H:%M:%S%:z')
        if [[ $label == explicit-default ]]; then
            mv "$data/alerts" "$temp/previous"
        else
            [[ ! -e $lock ]]
        fi
        printf '%s\n%s,75.0,50.0,40.0\n' "$header" "$stamp" > "$data/metrics.csv"
        expect 0 "${cmd[@]}"
        [[ -f $lock && -f $alert_lock ]]
        before=$(sha256sum "${records[@]}")
        stamp=$(date -u -d '@1800000000' '+%Y-%m-%dT%H:%M:%S%:z')
        printf '%s\n%s,90.0,50.0,40.0\n' "$header" "$stamp" > "$data/metrics.csv"
        for path in "$alert_lock" "$lock"; do
            cp "$temp/bytes" "$path"
            inode=$(stat -c '%d:%i' "$path")
            exec 7>>"$path"; flock -xn 7
            expect 6 "${cmd[@]}"
            exec 7>&-
            [[ $(stat -c '%d:%i' "$path") == "$inode" ]]
            cmp "$temp/bytes" "$path"
            mv "$path" "$path.saved"
            ln -s "$temp/bytes" "$path"
            expect 4 "${cmd[@]}"
            unlink "$path"
            ln "$temp/bytes" "$path"
            expect 4 "${cmd[@]}"
            unlink "$path"
            mkfifo "$path"
            expect 4 "${cmd[@]}"
            unlink "$path"
            mv "$path.saved" "$path"
            cmp "$temp/bytes" "$path"
            [[ $(sha256sum "${records[@]}") == "$before" ]]
        done
        expect 0 "${cmd[@]}"
        grep -q ',cpu,WARNING,CRITICAL,90.0,' "$data/alerts/events.csv"
        cmp "$temp/bytes" "$alert_lock"
        cmp "$temp/bytes" "$lock"
    done
    before=$(sha256sum "${records[@]}")
    mkdir "$temp/outside"
    cp "$temp/bytes" "$temp/outside/alerts.lock"
    mv "$repo/runtime" "$repo/runtime.saved"
    ln -s "$temp/outside" "$repo/runtime"
    expect 4 "${cmd[@]}"
    unlink "$repo/runtime"
    mv "$repo/runtime.saved" "$repo/runtime"
    ln -s "$temp/outside" "$temp/link"
    expect 4 "$alerts" --once --data-dir "$temp/link/nested"
    [[ ! -e $temp/outside/nested && $(sha256sum "${records[@]}") == "$before" ]]
    cmp "$temp/bytes" "$temp/outside/alerts.lock"
    echo 'PASS default, explicit-default and custom locks, contention and unsafe paths'
)
test_alerts() {
    sandbox
    freeze_clock
    local csv=$temp/data/metrics.csv out=$temp/data/alerts
    local header=timestamp,cpu_percent,memory_percent,disk_percent
    local -a alert=("$repo/scripts/alerts.sh" --once --data-dir "$temp/data")
    sample() {
        local ts
        ts=$(/usr/bin/date -u -d "@$1" '+%Y-%m-%dT%H:%M:%S%:z')
        printf '%s\n%s,%s,%s,%s\n' "$header" "$ts" "$2" "${3:-50.0}" "${4:-40.0}" > "$csv"
    }
    expect 3 "${alert[@]}"
    printf '%s\n' "$header" > "$csv"; expect 3 "${alert[@]}"
    sample 1799999820 74.9; expect 0 "${alert[@]}"
    [[ ! -e $out/events.csv ]]
    local n=1799999821 v
    for v in 75.0 90.0 90.0 89.0 88.0 87.9 73.0 72.9; do
        sample "$n" "$v"; expect 0 "${alert[@]}"; expect 0 "${alert[@]}"; ((n+=1))
    done
    diff -u <(printf '%s\n' WARNING CRITICAL WARNING NORMAL) <(tail -n +2 "$out/events.csv" | cut -d, -f4)
    [[ $(grep -c ',captured,mock$' "$out/delivery.csv") == 4 ]]
    grep -Fq 'To: ops@example.test' "$out/mock-mail.log"
    grep -Fq 'cpu 87.9% threshold 88% CRITICAL -> WARNING' "$out/mock-mail.log"
    sample "$n" 10.0 90.0 95.0; expect 0 "${alert[@]}"
    [[ $(grep -c ',NORMAL,CRITICAL,' "$out/events.csv") == 2 ]]
    local baseline
    baseline=$(sha256sum "$out/"{state.tsv,events.csv,delivery.csv})
    sample 1799999819 95.0; expect 3 "${alert[@]}"
    sample 1800000001 95.0; expect 3 "${alert[@]}"
    sample 1799999820 95.0; expect 3 "${alert[@]}"
    sample "$n" 10.1; expect 3 "${alert[@]}"
    for v in '100.1' '-0.1' '90' '2e1' '75.00' '3.0,4.0'; do
        sample 1800000000 "$v"; expect 3 "${alert[@]}"
    done
    for v in '2027-02-30T00:00:00+00:00' '2027-01-15T08:00:00Z' '2027-01-15T08:00:00+25:00'; do
        printf '%s\n%s,90.0,50.0,40.0\n' "$header" "$v" > "$csv"; expect 3 "${alert[@]}"
    done
    sample 1800000000 90.0; printf 'bad latest\n' >> "$csv"; expect 3 "${alert[@]}"
    sample 1800000000 90.0; truncate -s -1 "$csv"; expect 3 "${alert[@]}"
    sample 1800000000 90.0; sed -i '1s/cpu/CPU/' "$csv"; expect 3 "${alert[@]}"
    [[ $(sha256sum "$out/"{state.tsv,events.csv,delivery.csv}) == "$baseline" ]]
    sample 1800000000 90.0 90.0 95.0
    exec 7>"$repo/runtime/alerts.lock"; flock -n 7; expect 6 "${alert[@]}"; exec 7>&-
    printf 'EMAIL_TO=-oops@example.test\n' > "$repo/config/local.conf"; expect 2 "${alert[@]}"
    : > "$repo/config/local.conf"
    mv "$out/mock-mail.log" "$temp/capture"
    ln -s /dev/full "$out/mock-mail.log"
    expect 5 "${alert[@]}"
    grep -q ',failed,mock_capture_error$' "$out/delivery.csv"
    grep -q ',cpu,NORMAL,CRITICAL,90.0,90,' "$out/events.csv"
    baseline=$(sha256sum "$out/"{state.tsv,events.csv,delivery.csv})
    expect 0 "${alert[@]}"
    [[ $(sha256sum "$out/"{state.tsv,events.csv,delivery.csv}) == "$baseline" ]]
    printf 'corrupt\n' > "$out/state.tsv"; expect 4 "${alert[@]}"
    # Interrupt publication after events.csv is installed, before state.tsv is replaced.
    local isolated=$temp/recovery
    mkdir "$isolated"
    csv=$isolated/metrics.csv
    sample 1800000000 75.0
    cat > "$temp/bin/mv" <<'FAILMOVE'
#!/usr/bin/env bash
if [[ ${*: -1} == */alerts/state.tsv ]]; then exit 1; fi
exec /bin/mv "$@"
FAILMOVE
    chmod +x "$temp/bin/mv"
    local -a recovery=("$repo/scripts/alerts.sh" --once --data-dir "$isolated")
    expect 4 "${recovery[@]}"
    [[ -f $isolated/alerts/pending/state.tsv ]]
    /bin/mv "$temp/bin/mv" "$temp/mv-fixture"
    expect 0 "${recovery[@]}"
    [[ $(wc -l < "$isolated/alerts/events.csv") == 2 && ! -e $isolated/alerts/pending ]]
    grep -q $'cpu\t.*\tWARNING\t75.0' "$isolated/alerts/state.tsv"
    expect 4 "$repo/scripts/alerts.sh" --once --data-dir "$csv"
    echo 'PASS alert transitions, persistence, validation, locks and mock delivery'
}
test_recipients() (
    sandbox
    freeze_clock
    local alerts=$repo/scripts/alerts.sh config=$temp/recipient.conf
    local header=timestamp,cpu_percent,memory_percent,disk_percent
    local recipient stamp baseline data
    local -a command=("$alerts" --once --mail-mode real --config "$config")
    export FAKE_MAIL_CALLS="$temp/mailx.calls"
    cat > "$temp/bin/mailx" <<'FAKE'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FAKE_MAIL_CALLS"
if [[ $# == 1 && $1 == --help ]]; then
    printf '%s\n' 'Usage: mailx -s subject recipient'
    exit 0
fi
[[ $# == 3 && $1 == -s ]] || exit 91
cat >/dev/null
FAKE
    chmod +x "$temp/bin/mailx"
    [[ $(command -v mailx) == "$temp/bin/mailx" ]]

    stamp=$(date -u -d '@1799999940' '+%Y-%m-%dT%H:%M:%S%:z')
    for recipient in first.last@example.test first+alerts@example.test; do
        data=$temp/$recipient
        mkdir -- "$data"
        printf 'MAIL_ENABLED=1\nEMAIL_TO=%s\n' "$recipient" > "$config"
        printf '%s\n%s,75.0,50.0,40.0\n' "$header" "$stamp" > "$data/metrics.csv"
        expect 0 "${command[@]}" --data-dir "$data"
        grep -Fq -- " $recipient" "$FAKE_MAIL_CALLS"
        grep -Fq ",$recipient,submitted,mailx_exit_zero" "$data/alerts/delivery.csv"
    done

    # A new critical sample would change all three files if validation let it through.
    local -a records=("$data/alerts/"{state.tsv,events.csv,delivery.csv})
    baseline=$(sha256sum "${records[@]}")
    unlink "$FAKE_MAIL_CALLS"
    stamp=$(date -u -d '@1800000000' '+%Y-%m-%dT%H:%M:%S%:z')
    printf '%s\n%s,90.0,50.0,40.0\n' "$header" "$stamp" > "$data/metrics.csv"
    cp -- "$data/metrics.csv" "$temp/data/metrics.csv"
    for recipient in first..last@example.test .first@example.test first.@example.test; do
        printf 'MAIL_ENABLED=1\nEMAIL_TO=%s\n' "$recipient" > "$config"
        expect 2 "${command[@]}" --data-dir "$temp/data"
        grep -Fq 'invalid recipient' "$temp/stderr"
        [[ ! -e $temp/data/alerts && ! -e $FAKE_MAIL_CALLS ]]
        expect 2 "${command[@]}" --data-dir "$data"
        grep -Fq 'invalid recipient' "$temp/stderr"
        [[ ! -e $FAKE_MAIL_CALLS && $(sha256sum "${records[@]}") == "$baseline" ]]
    done
    echo 'PASS recipient validation before mailx invocation or alert state changes'
)
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    (test_alerts)
    test_locks
    test_recipients
fi
