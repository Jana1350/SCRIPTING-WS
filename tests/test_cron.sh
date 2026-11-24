#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/test_alerts.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/test_alerts.sh"
source_root=$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
sandbox
export FAKE_TABLE="$temp/table"
cat > "$temp/bin/crontab" <<'FAKE'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$1" >> "$FAKE_TABLE.calls"
if [[ $1 == -l ]]; then
    if [[ -e $FAKE_TABLE.error ]]; then echo "read failure" >&2; exit 1; fi
    if [[ ! -f $FAKE_TABLE ]]; then echo "no crontab for $(id -un)" >&2; exit 1; fi
    cat "$FAKE_TABLE"
else
    cp "$1" "$FAKE_TABLE"
    echo write >> "$FAKE_TABLE.writes"
fi
FAKE
chmod +x "$temp/bin/crontab"
[[ $(command -v crontab) == "$temp/bin/crontab" ]]
cron=$repo/scripts/setup_cron.sh
expect 0 "$cron"
cp "$temp/stdout" "$temp/preview"
[[ ! -e $FAKE_TABLE && ! -e $repo/runtime ]]
expect 2 "$cron" --print --mail-mode real
grep -Fq 'real mail requires MAIL_ENABLED=1' "$temp/stderr"
expect 2 "$cron" --install --mail-mode real
expect 2 "$cron" --uninstall --mail-mode real
expect 2 "$cron" --print --mail-mode
expect 2 "$cron" --print --mail-mode unsupported
expect 2 "$cron" --print --mail-mode real --mail-mode real
[[ ! -e $FAKE_TABLE && ! -e $repo/runtime ]]
expect 7 "$cron" --install
for f in main.sh report.sh rotate_logs.sh; do
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@"\n' > "$repo/scripts/$f"
    chmod +x "$repo/scripts/$f"
done
expect 0 "$cron" --install
cmp "$FAKE_TABLE" "$temp/preview"
[[ $(wc -l < "$FAKE_TABLE") == 6 ]]
! grep -Fq '%' "$FAKE_TABLE" || exit 1
# Exercise the shell commands from the preview using only fixture A/C commands.
for n in 2 3 4 5; do
    command_line=$(sed -n "${n}p" "$FAKE_TABLE" | cut -d' ' -f6-)
    /bin/sh -c "$command_line"
done
diff -u <(printf '%s\n' --once daily weekly '') "$repo/runtime/cron.log"
run_job() {
    local command_line
    command_line=$(sed -n "${1}p" "$temp/preview" | cut -d' ' -f6-)
    /bin/sh -c "$command_line"
}
# Standalone runs use a fixture collector. Integrated runs can supply A's scripts.
if [[ -n ${SYSGUARD_TEST_MONITOR_SCRIPTS:-} ]]; then
    cp -- "$SYSGUARD_TEST_MONITOR_SCRIPTS/"{monitor.sh,main.sh} "$repo/scripts/"
else
    cat > "$repo/scripts/main.sh" <<'COLLECT'
#!/usr/bin/env bash
set -eu
root=$(cd "$(dirname "$0")/.." && pwd -P)
exec 9>>"$root/runtime/metrics.lock"
flock -xn -E 6 9
mkdir -p "$root/data"
if [[ ! -e $root/data/metrics.csv ]]; then
    echo 'timestamp,cpu_percent,memory_percent,disk_percent' > "$root/data/metrics.csv"
fi
echo "$(date '+%Y-%m-%dT%H:%M:%S%:z'),75.0,50.0,40.0" >> "$root/data/metrics.csv"
exec 9>&-
exec "$root/scripts/alerts.sh" --once --mail-mode mock
COLLECT
fi
log=$repo/runtime/cron.log
exec 7>>"$repo/runtime/cron-maintenance.lock"; flock -xn 7
expect 0 run_job 2
[[ $(wc -l < "$repo/data/metrics.csv") == 2 && -s $repo/data/alerts/state.tsv ]]
expect 6 run_job 3
expect 6 run_job 4
expect 6 run_job 5
for name in daily-report weekly-report rotation; do grep -Fq "$name skipped: cron-maintenance.lock busy" "$log"; done
exec 7>&-
sample_before=$(sha256sum "$repo/data/metrics.csv" "$repo/data/alerts/state.tsv")
exec 7>>"$repo/runtime/cron-monitor.lock"; flock -xn 7
expect 6 run_job 2
grep -Fq 'monitor skipped: cron-monitor.lock busy' "$log"
exec 7>&-
exec 7>>"$repo/runtime/metrics.lock"; flock -xn 7
expect 6 run_job 2
grep -Fq 'monitor skipped: command reported lock contention (exit 6)' "$log"
expect 6 "$repo/scripts/alerts.sh" --once --mail-mode mock
exec 7>&-
[[ $(sha256sum "$repo/data/metrics.csv" "$repo/data/alerts/state.tsv") == "$sample_before" ]]
printf '#!/usr/bin/env bash\nexit 23\n' > "$repo/scripts/report.sh"
expect 23 run_job 3
grep -Fq 'daily-report failed: command exit 23' "$log"
before='# existing comment'
after='0 4 * * * /bin/true'
{ echo "$before"; cat "$temp/preview"; echo "$after"; } > "$FAKE_TABLE"
cp "$FAKE_TABLE" "$temp/installed"
expect 0 "$cron" --install
cmp "$FAKE_TABLE" "$temp/installed"
[[ $(wc -l < "$FAKE_TABLE.writes") == 1 ]]
expect 0 "$cron" --help
grep -Fq 'setup_cron.sh --uninstall [--config FILE]' "$temp/stdout"
expect 0 "$cron" --uninstall --config 'config/missing uninstall.conf'
diff -u <(printf '%s\n' "$before" "$after") "$FAKE_TABLE"
expect 0 "$cron" --uninstall
[[ $(wc -l < "$FAKE_TABLE.writes") == 2 ]]
expect 0 "$cron" --install
expect 0 "$cron" --install
expect 0 "$cron" --uninstall
diff -u <(printf '%s\n' "$before" "$after") "$FAKE_TABLE"

printf '%s\n' MAIL_ENABLED=1 > "$repo/config/local.conf"
expect 0 "$cron" --print
cmp "$temp/stdout" "$temp/preview"
printf '%s\n' MAIL_ENABLED=0 > "$temp/disabled mail.conf"
expect 2 "$cron" --print --mail-mode real --config "$temp/disabled mail.conf"
expect 0 "$cron" --print --mail-mode real
cp "$temp/stdout" "$temp/real-preview"
sed "2s/$/ '--mail-mode' 'real'/" "$temp/preview" > "$temp/expected-real"
cmp "$temp/expected-real" "$temp/real-preview"
expect 0 "$cron" --install --mail-mode real
diff -u <(printf '%s\n' "$before" "$after"; cat "$temp/real-preview") "$FAKE_TABLE"
writes=$(wc -l < "$FAKE_TABLE.writes")
expect 0 "$cron" --install --mail-mode real
[[ $(wc -l < "$FAKE_TABLE.writes") == "$writes" ]]

# Run the rendered monitor job with the real orchestrator, a fixture
# collector, and a test-only PATH that resolves mailx to a capture stub.
cp -- "$source_root/scripts/main.sh" "$repo/scripts/"
mv -- "$repo/data" "$temp/prior-data"
cat > "$repo/scripts/monitor.sh" <<'COLLECT'
#!/usr/bin/env bash
set -eu
[[ ${1-} == --once && ( $# == 1 || ( $# == 3 && $2 == --config && -f $3 ) ) ]] || exit 2
root=$(cd "$(dirname "$0")/.." && pwd -P)
exec 9>>"$root/runtime/metrics.lock"
flock -xn -E 6 9
mkdir -p "$root/data"
printf '%s\n%s,90.0,50.0,40.0\n' 'timestamp,cpu_percent,memory_percent,disk_percent' \
    "$(date -u '+%Y-%m-%dT%H:%M:%S%:z')" > "$root/data/metrics.csv"
COLLECT
export SYSGUARD_CRON_TEST_BIN="$temp/bin" SYSGUARD_CRON_TEST_CAPTURE="$temp/mail-capture"
cat > "$temp/bin/mailx" <<'STUB'
#!/usr/bin/env bash
if [[ $# == 1 && $1 == --help ]]; then
    printf '%s\n' 'Usage: mailx -s subject recipient'
    exit 0
fi
[[ $# == 3 && $1 == -s && $3 == ops@example.test ]] || exit 91
cat > "$SYSGUARD_CRON_TEST_CAPTURE"
STUB
chmod +x -- "$repo/scripts/monitor.sh" "$temp/bin/mailx"
run_real_job() {
    local real_command fixture_command
    real_command=$(sed -n '2p' "$1" | cut -d' ' -f6-)
    [[ $real_command == *'PATH=/usr/bin:/bin '* ]] || return 1
    # shellcheck disable=SC2016
    fixture_command=${real_command/'PATH=/usr/bin:/bin'/'PATH="$SYSGUARD_CRON_TEST_BIN:/usr/bin:/bin"'}
    [[ $fixture_command != "$real_command" && $(command -v mailx) == "$temp/bin/mailx" ]] || return 1
    /bin/sh -c "$fixture_command"
}
expect 0 run_real_job "$temp/real-preview"
grep -Fq ',submitted,mailx_exit_zero' "$repo/data/alerts/delivery.csv"
grep -Fq '90.0%' "$SYSGUARD_CRON_TEST_CAPTURE"

# A complete explicit config still needs the checkout's defaults in real mode.
complete_config=$repo/config/complete.conf
sed 's/^MAIL_ENABLED=0$/MAIL_ENABLED=1/' "$repo/config/defaults.conf" > "$complete_config"
expect 0 "$cron" --print --mail-mode real --config "$complete_config"
cp "$temp/stdout" "$temp/explicit-real-preview"
cp "$FAKE_TABLE" "$temp/defaults-test-table"
cp "$FAKE_TABLE.calls" "$temp/defaults-test-calls"
mv -- "$repo/config/defaults.conf" "$temp/saved-defaults.conf"
for action in --print --install; do
    expect 2 "$cron" "$action" --mail-mode real --config "$complete_config"
    [[ ! -s $temp/stdout ]]
    grep -Fq 'missing default config' "$temp/stderr"
    cmp "$FAKE_TABLE" "$temp/defaults-test-table"
    cmp "$FAKE_TABLE.calls" "$temp/defaults-test-calls"
done
expect 2 run_real_job "$temp/explicit-real-preview"
grep -Fq 'missing default config' "$repo/runtime/cron.log"
mv -- "$temp/saved-defaults.conf" "$repo/config/defaults.conf"
expect 0 "$cron" --print --mail-mode real --config "$complete_config"
cmp "$temp/stdout" "$temp/explicit-real-preview"
expect 0 "$cron" --install --mail-mode real --config "$complete_config"
diff -u <(printf '%s\n' "$before" "$after"; cat "$temp/explicit-real-preview") "$FAKE_TABLE"
mv -- "$repo/data" "$temp/data-before-defaults-test"
expect 0 run_real_job "$temp/explicit-real-preview"
grep -Fq ',submitted,mailx_exit_zero' "$repo/data/alerts/delivery.csv"
echo 'PASS real cron preview, install and scheduled command require defaults with an explicit config'

expect 0 "$cron" --uninstall
diff -u <(printf '%s\n' "$before" "$after") "$FAKE_TABLE"
echo 'PASS cron real-mail opt-in, fake installation idempotence and fixture mail capture'

# Use a valid file so stripping a suffix would allow the command to proceed.
relative_config='config/valid cron.conf'
absolute_config=$repo/$relative_config
printf '%s\n' MAIL_ENABLED=1 > "$absolute_config"
expect 0 "$cron" --print --config "$relative_config"
cp "$temp/stdout" "$temp/relative-config-preview"
expect 0 "$cron" --print --config "$absolute_config"
cmp "$temp/stdout" "$temp/relative-config-preview"
[[ $(grep -Fc -- "/$relative_config'" "$temp/stdout") == 4 ]]
cp "$FAKE_TABLE" "$temp/path-test-table"
cp "$FAKE_TABLE.calls" "$temp/path-test-calls"
for bad_config in "$absolute_config"$'\n' "$relative_config"$'\n\n' \
    "$repo/config/valid"$'\n'' cron.conf' "$absolute_config"$'\r' \
    "$absolute_config"$'\t' "$absolute_config%"; do
    for action in --print --install; do
        expect 2 "$cron" "$action" --config "$bad_config"
        [[ ! -s $temp/stdout ]]
        grep -Fq 'path unsafe for cron' "$temp/stderr"
        cmp "$FAKE_TABLE" "$temp/path-test-table"
        cmp "$FAKE_TABLE.calls" "$temp/path-test-calls"
    done
done
echo 'PASS cron validates raw config paths before rendering or accessing crontab'

# Make the path left by newline stripping a real checkout as well.
cp -a -- "$repo" "$temp/root-checkout"
for suffix in $'\n' $'\n\n' $'\nembedded' $'\r' $'\t' '%'; do
    unsafe_repo=$temp/root-checkout$suffix
    cp -a -- "$temp/root-checkout" "$unsafe_repo"
    for action in --print --install; do
        expect 2 "$unsafe_repo/scripts/setup_cron.sh" "$action"
        [[ ! -s $temp/stdout ]]
        grep -Fq 'path unsafe for cron' "$temp/stderr"
        cmp "$FAKE_TABLE" "$temp/path-test-table"
        cmp "$FAKE_TABLE.calls" "$temp/path-test-calls"
    done
done
echo 'PASS cron rejects unsafe checkout roots before rendering or accessing crontab'

for malformed in begin end duplicate; do
    case $malformed in
        begin) head -1 "$temp/preview" > "$FAKE_TABLE";;
        end) tail -1 "$temp/preview" > "$FAKE_TABLE";;
        duplicate) cat "$temp/preview" "$temp/preview" > "$FAKE_TABLE";;
    esac
    cp "$FAKE_TABLE" "$temp/original"
    expect 4 "$cron" --install
    expect 4 "$cron" --uninstall
    cmp "$FAKE_TABLE" "$temp/original"
done
touch "$FAKE_TABLE.error"
expect 4 "$cron" --install
cmp "$FAKE_TABLE" "$temp/original"
echo 'PASS cron preview, scheduled command quoting, preservation, idempotence and unsafe table refusal'
