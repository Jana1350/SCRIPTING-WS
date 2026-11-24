#!/usr/bin/env bash
set -euo pipefail
umask 077
repo=$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
checkout="$scratch/checkout with spaces"
mkdir -p "$checkout"/{scripts,config,tests} "$scratch/bin" "$scratch/home"
cp -- "$repo/sysguard.sh" "$repo/.gitignore" "$checkout/"
cp -- "$repo"/scripts/{config,alerts,setup,setup_cron}.sh "$checkout/scripts/"
cp -- "$repo"/config/{defaults.conf,example.local.conf} "$checkout/config/"
git -C "$checkout" init -q
export TABLE="$scratch/table" CALLS="$scratch/calls" OPEN_LOG="$scratch/open" MAIL_LOG="$scratch/mail"
export CRON_WRITES="$scratch/cron-writes" CRON_READS="$scratch/cron-reads" FOREIGN="$scratch/foreign"
export HOME="$scratch/home" PATH="$scratch/bin:/usr/bin:/bin" TZ=Etc/UTC LC_ALL=C
unset WSL_INTEROP
printf '%s\n' '17 4 * * * /bin/true # unrelated' > "$scratch/unrelated"
cp "$scratch/unrelated" "$TABLE"
: > "$CALLS"; : > "$CRON_WRITES"
printf '0\n' > "$CRON_READS"

cat > "$scratch/bin/crontab" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ $1 == -l ]]; then
    reads=$(< "$CRON_READS")
    ((reads+=1))
    printf '%s\n' "$reads" > "$CRON_READS"
    if [[ $reads == "${CRON_SWAP_AT-}" ]]; then cp "$FOREIGN" "$TABLE"; fi
    if [[ -e $TABLE ]]; then cat "$TABLE"
    else printf 'no crontab for %s\n' "$(id -un)" >&2; exit 1; fi
else
    [[ ${FAIL_CRON_WRITE:-0} == 0 ]] || exit 73
    cp -- "$1" "$TABLE"
    printf 'write\n' >> "$CRON_WRITES"
fi
STUB
cat > "$scratch/bin/env" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    'PATH=/usr/bin:/bin sh -c command -v mailx')
        [[ ${MISSING_MAIL:-0} == 0 ]] || exit 1
        command -v mailx ;;
    '-i PATH=/usr/bin:/bin HOME='*' LC_ALL=C sh -c mailx --help') mailx --help ;;
    '-u TZ date +%Z %z') echo 'UTC +0000' ;;
    *) exec /usr/bin/env "$@" ;;
esac
STUB
cat > "$scratch/bin/mailx" <<'STUB'
#!/bin/bash
if [[ ${1-} == --help ]]; then echo 'mailx -s subject'; exit 0; fi
echo forbidden >> "$MAIL_LOG"
exit 99
STUB
printf '#!/bin/sh\necho active\n' > "$scratch/bin/systemctl"
cat > "$scratch/bin/xdg-open" <<'STUB'
#!/bin/bash
printf '%s\n' "$1" >> "$OPEN_LOG"
exit "${OPENER_STATUS:-0}"
STUB
printf '#!/bin/sh\nexit 0\n' > "$scratch/bin/pdfinfo"
cat > "$scratch/bin/wslpath" <<'STUB'
#!/bin/bash
[[ $# == 2 && $1 == -w && $2 == *'checkout with spaces'* ]] || exit 1
printf '\\\\wsl.localhost\\Ubuntu%s\n' "${2//\//\\}"
STUB
cat > "$scratch/bin/powershell.exe" <<'STUB'
#!/bin/bash
set -euo pipefail
[[ $# == 4 && $1 == -NoProfile && $2 == -NonInteractive && $3 == -Command ]]
[[ $4 == *'Invoke-Item -LiteralPath $p -ErrorAction Stop'* ]]
re="FromBase64String\('([A-Za-z0-9+/=]+)'\)"
[[ $4 =~ $re ]]
printf 'WSL %s\n' "$(printf '%s' "${BASH_REMATCH[1]}" | base64 -d)" >> "$OPEN_LOG"
exit "${WINDOWS_STATUS:-0}"
STUB
chmod 700 "$scratch/bin/"*

cat > "$checkout/scripts/main.sh" <<'STUB'
#!/usr/bin/env bash
set -eu
printf 'main %s\n' "$*" >> "$CALLS"
if [[ $1 == --once ]]; then
    [[ $2 == --data-dir ]]
    [[ $# == 3 || ( $# == 5 && $4 == --mail-mode && $5 == real ) ]]
    mkdir -p -- "$3"
    row="$(date '+%Y-%m-%dT%H:%M:%S%:z'),20.0,40.0,60.0"
    printf '%s\n' timestamp,cpu_percent,memory_percent,disk_percent "$row" > "$3/metrics.csv"
    printf '%s\n' "$row"
    if [[ ${5-} == real && ${SUBMIT_FIXTURE:-0} == 1 ]]; then
        mkdir -p -- "$3/alerts"
        printf '%s,%s,%s,%s,%s\n' "${row%%,*}" synthetic fixture@example.test submitted mailx_exit_zero >> "$3/alerts/delivery.csv"
    fi
fi
exit "${MAIN_STATUS:-0}"
STUB
cat > "$checkout/scripts/monitor.sh" <<'STUB'
#!/usr/bin/env bash
printf 'monitor %s\n' "$*" >> "$CALLS"
exit "${WATCH_STATUS:-0}"
STUB
cat > "$checkout/scripts/report.sh" <<'STUB'
#!/usr/bin/env bash
set -eu
printf 'report %s\n' "$*" >> "$CALLS"
if [[ ${REPORT_STATUS:-0} != 0 ]]; then echo 'fixture render failed' >&2; exit "$REPORT_STATUS"; fi
root=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
dir=$root/reports/$1
name=2026-11-23
if [[ $1 == weekly ]]; then name=2026-11-16_to_2026-11-22; fi
if [[ $1 == today ]]; then name=2026-11-24; fi
mkdir -p "$dir" "$root/reports/charts"
printf '<h2>NO DATA</h2>\n' > "$dir/$name.html"
printf 'Wrote %s\n' "$dir/$name.html"
if [[ ${WITHOUT_PDF:-0} == 0 ]]; then
    printf '%%PDF-1.7\n' > "$dir/$name.pdf"
    printf 'Wrote %s\n' "$dir/$name.pdf"
fi
STUB
cat > "$checkout/scripts/rotate_logs.sh" <<'STUB'
#!/usr/bin/env bash
printf 'rotate %s\n' "$*" >> "$CALLS"
echo 'Retention preview fixture'
exit 0
STUB
cat > "$checkout/tests/run_all.sh" <<'STUB'
#!/usr/bin/env bash
echo regression >> "$CALLS"
exit 4
STUB
chmod 755 "$checkout/scripts/"*.sh

fail() { printf 'FAIL: %s\n' "$*" >&2; cat "$scratch/output" >&2; exit 1; }
contains() { grep -Fq -- "$1" "$scratch/output" || fail "missing output: $1"; }
absent() { if grep -Fq -- "$1" "$scratch/output"; then fail "unexpected output: $1"; fi; }
run() {
    # The launcher is always invoked by absolute path from another directory.
    (cd "$scratch"; /usr/bin/timeout -k 3s 15s bash "$checkout/sysguard.sh") <<< "$1" > "$scratch/output" 2>&1
}
expect_table() { cmp "$1" "$TABLE" || fail 'crontab differs'; }
seed() {
    cat "$scratch/unrelated" > "$TABLE"
    bash "$checkout/scripts/setup_cron.sh" --print "$@" >> "$TABLE"
}

run $'\n90\n0'
contains 'SysGuard | Terminal Control Center'
contains 'CONFIGURATION'
contains 'REPORTS AND STORAGE'
contains 'SYSTEM MANAGEMENT'
contains '11. Diagnostics and testing'
absent $'\033'
[[ $(grep -Fc 'Enter a listed number.' "$scratch/output") == 2 ]] || fail 'invalid or blank input'
(cd "$scratch"; "$checkout/sysguard.sh" < /dev/null) > "$scratch/output" 2>&1
contains 'SysGuard closed.'
printf 'PASS menu, empty/invalid input, EOF, paths with spaces, and both entry points\n'

run $'1\nn\nn\nn\n0'
contains 'Setup wizard finished (exit 0).'
expect_table "$scratch/unrelated"
test ! -e "$checkout/config/local.conf"
run $'2\nn\n0'
contains 'Installation declined.'
expect_table "$scratch/unrelated"
test ! -s "$CRON_WRITES"
run $'2\ny\n0'
contains 'Schedule installation finished (exit 0).'
grep -Fxq '# BEGIN SysGuard System Health Monitor v1' "$TABLE" || fail 'no schedule installed'
cp "$TABLE" "$scratch/owned"
run $'9\n10\nn\n0'
contains 'scheduled delivery: mock'
contains 'Removal declined.'
expect_table "$scratch/owned"
run $'10\ny\n0'
contains 'Schedule removal finished (exit 0).'
expect_table "$scratch/unrelated"
printf 'PASS guarded wizard, read-only preview, declined installs/removals and confirmed cron edits\n'

sed "s|$checkout|$scratch/second checkout|g" "$scratch/owned" > "$FOREIGN"
cp "$FOREIGN" "$TABLE"
writes=$(wc -l < "$CRON_WRITES")
run $'9\n1\nn\n2\n10\n0'
contains 'second checkout (foreign), scheduled delivery: mock'
contains 'Wizard skipped to protect'
contains 'Installation refused'
contains 'Removal refused'
expect_table "$FOREIGN"
test "$(wc -l < "$CRON_WRITES")" = "$writes"
run $'1\ny\n1\nforeign-test@example.test\ny\n4\n50\n90\ny\n0\n0'
contains 'The existing installation remains active.'
contains 'The foreign schedule stays unchanged.'
absent 'foreign-test@example.test'
grep -Fxq EMAIL_TO=foreign-test@example.test "$checkout/config/local.conf"
grep -Fxq CPU_WARNING=50 "$checkout/config/local.conf"
expect_table "$FOREIGN"
test "$(wc -l < "$CRON_WRITES")" = "$writes"
cat "$scratch/unrelated" > "$TABLE"
printf '0\n' > "$CRON_READS"
CRON_SWAP_AT=4 run $'2\ny\n0'
contains 'Cron write refused'
contains 'Schedule installation finished (exit 4).'
expect_table "$FOREIGN"
test "$(wc -l < "$CRON_WRITES")" = "$writes"
printf 'PASS foreign ownership across wizard/start/stop and post-confirmation crontab change\n'

cat "$scratch/unrelated" > "$TABLE"
run $'3\n0'
contains 'CPU: 20.0% | Memory: 40.0% | Disk: 60.0%'
contains 'Sample saved:'
contains 'Alert processing completed in mock mode.'
MAIN_STATUS=5 run $'3\n0'
contains 'Monitor now finished (exit 5).'
contains 'Sample saved:'
mv "$checkout/data/metrics.csv" "$scratch/saved-sample"
WATCH_STATUS=9 run $'4\n0'
contains 'Foreground sampling.'
contains 'Foreground monitor finished (exit 9).'
cp "$scratch/saved-sample" "$checkout/data/metrics.csv"
cp "$scratch/owned" "$TABLE"
python3 - "$checkout" "$scratch" <<'PY'
import os, signal, subprocess, sys, time
from pathlib import Path
checkout, scratch = map(Path,sys.argv[1:])
log = scratch/'interrupt'
with log.open('w') as output:
    p = subprocess.Popen(['bash', checkout/'sysguard.sh'], stdin=subprocess.PIPE,
                         stdout=output, stderr=subprocess.STDOUT, start_new_session=True, text=True)
    try:
        p.stdin.write('4\n')
        p.stdin.flush()
        end=time.monotonic()+5
        while 'Reading saved measurements.' not in log.read_text():
            assert p.poll() is None and time.monotonic()<end, log.read_text()
            time.sleep(.05)
        os.killpg(p.pid,signal.SIGINT)
        while log.read_text().count('SysGuard | Terminal Control Center')<2:
            assert p.poll() is None and time.monotonic()<end, log.read_text()
            time.sleep(.05)
        p.communicate('0\n',timeout=3)
        assert p.returncode==0 and 'SysGuard closed.' in log.read_text(),log.read_text()
    finally:
        if p.poll() is None:
            os.killpg(p.pid,signal.SIGKILL)
            p.wait()
PY
printf 'PASS sample dispatch, downstream error status, foreground monitor and saved-view SIGINT\n'

cat "$scratch/unrelated" > "$TABLE"
run $'5\n1\nrecipient@example.test\ny\n4\n0\n90\n4\n50\n91\ny\n5\n51\n92\ny\n6\n52\n93\ny\n0\n0'
contains 'Private settings saved.'
contains 'Candidate configuration validation finished (exit 2).'
absent 'recipient@example.test'
config="$checkout/config/local.conf"
[[ $(stat -c %a "$config") == 600 ]] || fail 'private mode'
grep -Fxq EMAIL_TO=recipient@example.test "$config"
grep -Fxq CPU_WARNING=50 "$config"
grep -Fxq MEMORY_WARNING=51 "$config"
grep -Fxq DISK_WARNING=52 "$config"
run $'5\n7\ny\n0\n0'
grep -Fxq EMAIL_TO=recipient@example.test "$config"
for setting in CPU_WARNING=75 CPU_CRITICAL=90 MEMORY_WARNING=75 MEMORY_CRITICAL=90 DISK_WARNING=80 DISK_CRITICAL=95; do
    grep -Fxq "$setting" "$config"
done
MISSING_MAIL=1 run $'5\n2\n0\n0'
contains 'Settings operation finished (exit 7).'
run $'5\n2\ny\n0\n0'
grep -Fxq MAIL_ENABLED=1 "$config"
run $'2\nn\ny\n0'
contains 'Schedule installation finished (exit 0).'
if grep -Fq -- "'--mail-mode' 'real'" "$TABLE"; then fail 'real selected without consent'; fi
run $'2\ny\ny\n0'
grep -Fq -- "'--mail-mode' 'real'" "$TABLE"
cp "$checkout/data/metrics.csv" "$scratch/real-metrics-before"
mkdir -p "$checkout/data/alerts"
printf 'sentinel\n' > "$checkout/data/alerts/state.tsv"
cp "$CALLS" "$scratch/before-cancel"
(cd "$scratch"; bash "$checkout/sysguard.sh") < <(printf '3\n') > "$scratch/output" 2>&1
contains 'Monitoring cancelled.'
cmp "$CALLS" "$scratch/before-cancel"
run $'3\nn\n0'
contains 'separate manual sample history'
contains 'Alert processing completed in mock mode.'
[[ $(tail -n 1 "$CALLS") == "main --once --data-dir $checkout/data/manual" ]]
cmp "$checkout/data/metrics.csv" "$scratch/real-metrics-before"
grep -Fxq 'sentinel' "$checkout/data/alerts/state.tsv"
run $'3\ny\n0'
contains 'No transport submission was confirmed'
[[ $(tail -n 1 "$CALLS") == "main --once --data-dir $checkout/data --mail-mode real" ]]
SUBMIT_FIXTURE=1 run $'3\ny\n0'
contains '1 submission(s) accepted by mailx'
contains 'Check the inbox separately.'
absent 'fixture@example.test'
MAIN_STATUS=5 run $'3\ny\n0'
contains 'Alert delivery or capture failed in real mode.'
contains 'Monitor now finished (exit 5).'
cp "$CALLS" "$scratch/before-failed-config"
printf '%s\n' UNKNOWN_SETTING=1 >> "$config"
run $'3\n0'
contains 'Configuration validation finished (exit 2).'
cmp "$CALLS" "$scratch/before-failed-config"
sed -i '/^UNKNOWN_SETTING=/d' "$config"
cp "$scratch/owned" "$TABLE"
run $'3\ny\n0'
[[ $(tail -n 1 "$CALLS") == "main --once --data-dir $checkout/data/manual-real --mail-mode real" ]]
cp "$scratch/unrelated" "$TABLE"
run $'3\ny\n0'
[[ $(tail -n 1 "$CALLS") == "main --once --data-dir $checkout/data/manual-real --mail-mode real" ]]

seed --config "$config" --mail-mode real
cp "$TABLE" "$scratch/explicit"
cp "$config" "$scratch/config-original"
run $'5\n3\ny\n4\n50\n90\n0\n2\n0'
contains 'explicit real schedule remains enabled'
contains 'This private file is used by an explicit schedule.'
contains 'Installation refused'
expect_table "$scratch/explicit"
cmp "$config" "$scratch/config-original"
seed --mail-mode real
cp "$TABLE" "$scratch/real"
FAIL_CRON_WRITE=1 run $'5\n3\ny\n0\n0'
contains 'Scheduled mail change finished (exit 4).'
expect_table "$scratch/real"
cmp "$config" "$scratch/config-original"
run $'5\n3\ny\n0\n0'
contains 'Local email disabled and recipient cleared.'
grep -Fxq MAIL_ENABLED=0 "$config"
grep -Fxq EMAIL_TO= "$config"
if grep -Fq -- "'--mail-mode' 'real'" "$TABLE"; then fail 'OFF left real scheduling'; fi
cmp "$TABLE" "$scratch/owned"
mv "$config" "$scratch/private-saved"
ln -s "$scratch/private-saved" "$config"
cp "$CALLS" "$scratch/calls-before"
run $'9\n3\n0'
contains 'Unsafe configuration path.'
contains 'Configuration could not be validated (exit 2).'
cmp "$CALLS" "$scratch/calls-before"
unlink "$config"
mv "$scratch/private-saved" "$config"
printf 'PASS private config, all threshold reset keys, real opt-in, explicit-config protection and safe OFF\n'

run $'7\n2\nn\n4\nn\n7\nn\n0\n0'
contains 'No verified daily PDF was found'
contains 'The today report folder is unavailable'
contains 'No HTML reports or PNG charts found.'
contains 'Use Generate Reports (6)'
REPORT_STATUS=3 run $'6\n2\n0\n0'
contains 'fixture render failed'
contains 'daily report finished (exit 3).'
absent 'Open '
run $'6\n4\nn\nn\n0\n0'
contains 'Report period (UTC): 2026-11-23'
contains 'Report period (UTC): 2026-11-16_to_2026-11-22'
contains 'NO DATA: the report succeeded'
test ! -e "$OPEN_LOG"
run $'7\n1\ny\n1\nn\n0\n0\n0'
contains 'No current-day PDF is available'
contains "$checkout/reports/today/2026-11-24.pdf"
test ! -e "$OPEN_LOG"
OPENER_STATUS=12 run $'7\n2\ny\n0\n0'
contains 'Opener failed (exit 12).'
contains 'Fallback (Linux desktop): xdg-open '
absent 'Opener accepted'
grep -Fxq "$checkout/reports/daily/2026-11-23.pdf" "$OPEN_LOG"
WSL_INTEROP=fixture run $'7\n1\ny\n4\ny\n0\n0'
grep -Fxq "WSL \\\\wsl.localhost\\Ubuntu${checkout//\//\\}\\reports\\today\\2026-11-24.pdf" "$OPEN_LOG"
grep -Fxq "WSL \\\\wsl.localhost\\Ubuntu${checkout//\//\\}\\reports\\today" "$OPEN_LOG"
contains 'Opener accepted:'
WINDOWS_STATUS=1 WSL_INTEROP=fixture run $'7\n4\ny\n0\n0'
contains 'Opener failed (exit 1).'
contains "Fallback (WSL): explorer.exe \"\$(wslpath -w "
absent 'Opener accepted'
chart="$checkout/reports/charts/chart with spaces & symbols.png"
touch "$chart"
run $'7\n7\n1\ny\n7\n4\ny\n0\n0'
grep -Fxq "$checkout/reports/today/2026-11-24.html" "$OPEN_LOG"
grep -Fxq "$chart" "$OPEN_LOG"
WSL_INTEROP=fixture run $'7\n7\n4\ny\n0\n0'
grep -Fxq "WSL \\\\wsl.localhost\\Ubuntu${chart//\//\\}" "$OPEN_LOG"
WITHOUT_PDF=1 run $'6\n3\n0\n0'
contains 'This run did not publish a PDF.'
printf 'PASS report dispatch, NO DATA, missing artifacts, declined and failed PDF opening\n'

: > "$CALLS"
run $'8\n2\n3\n4\nn\n0\n11\n2\nn\n2\ny\n0\n0'
contains 'No historical gzip archives found.'
contains 'Retention preview finished (exit 0).'
contains 'Regression suites finished (exit 4).'
printf '%s\n' 'rotate --dry-run' 'regression' | cmp - "$CALLS"
run $'8\n4\ny\n0\n0'
contains 'Rotation finished (exit 0).'
mkdir "$scratch/short-path"
for tool in bash cat dirname mktemp rm tail; do ln -s "/usr/bin/$tool" "$scratch/short-path/$tool"; done
PATH="$scratch/short-path" run $'11\n1\n0\n0'
contains 'gnuplot: unavailable'
contains 'crontab: unavailable'
PATH="$scratch/short-path" run $'7\n4\ny\n0\n0'
contains 'No graphical opener is available.'
contains "Path: $checkout/reports/today"
contains 'Fallback (Linux desktop): xdg-open '
test ! -e "$MAIL_LOG"
if compgen -G "$checkout/config/.sysguard-*.log" >/dev/null; then fail 'staging file remains'; fi
printf 'PASS history, regression dispatch, missing dependencies, and zero mail calls\n'
