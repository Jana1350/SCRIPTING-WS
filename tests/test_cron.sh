#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/test_alerts.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/test_alerts.sh"
sandbox
export FAKE_TABLE="$temp/table"
cat > "$temp/bin/crontab" <<'FAKE'
#!/usr/bin/env bash
set -eu
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
expect 0 "$cron" --uninstall
diff -u <(printf '%s\n' "$before" "$after") "$FAKE_TABLE"
expect 0 "$cron" --uninstall
[[ $(wc -l < "$FAKE_TABLE.writes") == 2 ]]
expect 0 "$cron" --install
expect 0 "$cron" --install
expect 0 "$cron" --uninstall
diff -u <(printf '%s\n' "$before" "$after") "$FAKE_TABLE"
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
