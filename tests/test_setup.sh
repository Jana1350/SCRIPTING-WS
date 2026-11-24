#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/test_alerts.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/test_alerts.sh"
source_root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
sandbox
export FAKE_TABLE="$temp/table" MAIL_CALLS="$temp/mail-calls"
cp "$source_root"/scripts/{setup,main,monitor,report,rotate_logs}.sh "$repo/scripts/"
cp "$source_root/.gitignore" "$repo/"
cp "$source_root/config/defaults.conf" "$repo/config/"
# The collector is deterministic. The orchestrator, alert processing, config
# validation, generated schedule and managed-block installer are the real scripts.
cat > "$repo/scripts/monitor.sh" <<'STUB'
#!/usr/bin/env bash
set -eu
cd "$(dirname -- "$0")/.."
mkdir -p data
printf '%s\n' 'timestamp,cpu_percent,memory_percent,disk_percent' "$(date '+%Y-%m-%dT%H:%M:%S%:z'),5.0,10.0,15.0" > data/metrics.csv
STUB
cat > "$temp/bin/crontab" <<'STUB'
#!/usr/bin/env bash
set -eu
if [[ $1 == -l ]]; then cat "$FAKE_TABLE"; else cp -- "$1" "$FAKE_TABLE"; echo write >> "$FAKE_TABLE.writes"; fi
STUB
cat > "$temp/bin/mailx" <<'STUB'
#!/usr/bin/env bash
set -eu
if [[ $1 == --help ]]; then echo 'mailx -s subject'; exit; fi
[[ $# == 3 && $1 == -s && $3 == "${TEST_RECIPIENT:-person@example.test}" ]]
cat >/dev/null
echo submitted >> "$MAIL_CALLS"
STUB
# Resolve the cron-only mail lookup to our fixture, independent of host packages.
cat > "$temp/bin/env" <<'STUB'
#!/bin/bash
if [[ $* == 'PATH=/usr/bin:/bin sh -c command -v mailx' ]]; then command -v mailx; exit; fi
exec /usr/bin/env "$@"
STUB
printf '#!/bin/sh\nexit 0\n' > "$temp/bin/systemctl"
chmod +x "$temp/bin/"* "$repo/scripts/monitor.sh"
printf '%s\n' '0 8 * * * unrelated-private-job' > "$FAKE_TABLE"
cp "$FAKE_TABLE" "$temp/before"
run() {
    bash "$repo/scripts/setup.sh" <<< "$1" > "$temp/output" 2>&1
    if grep -Eq 'person@example.test|replacement@example.test|unrelated-private-job' "$temp/output"; then echo 'private information in output' >&2; exit 1; fi
}
run $'y\nn\ny\nn'
[[ -s $repo/data/metrics.csv && ! -e $repo/config/local.conf && ! -e $MAIL_CALLS ]]
cmp "$FAKE_TABLE" "$temp/before"
grep -q 'sample collected' "$temp/output"

conf=$repo/config/local.conf
printf '%s\n' '# Keep my settings' 'CPU_WARNING=70' 'MAIL_ENABLED=0' 'EMAIL_TO=' > "$conf"
cp "$conf" "$temp/original"
run $'n\ny\ninvalid recipient\nn'
grep -q 'Invalid recipient' "$temp/output"
cmp "$conf" "$temp/original"
run $'n\ny\nperson@example.test\nn\nn'
grep -q 'Configure the mail transport' "$temp/output"
cmp "$conf" "$temp/original"
[[ ! -e $MAIL_CALLS ]]
run $'n\ny\nperson@example.test\ny\nn\nn'
cmp "$conf" "$temp/original"
[[ ! -e $MAIL_CALLS ]]
run $'n\ny\nperson@example.test\ny\ny\nn\ny\nn'
grep -q 'inbox unconfirmed' "$temp/output"
cmp "$conf" "$temp/original"
cmp "$FAKE_TABLE" "$temp/before"
[[ $(wc -l < "$MAIL_CALLS") == 1 ]]
run $'n\ny\nperson@example.test\ny\ny\ny\ny\ny\ny'
grep -q 'Managed schedule: real' "$temp/output"
grep -q '^# Keep my settings$' "$conf"
grep -qx CPU_WARNING=70 "$conf"
[[ $(grep -c '^EMAIL_TO=' "$conf") == 1 && $(grep -c '^MAIL_ENABLED=1$' "$conf") == 1 ]]
[[ $(stat -c %a "$conf") == 600 && $(wc -l < "$MAIL_CALLS") == 2 ]]
grep -Fxq "$(cat "$temp/before")" "$FAKE_TABLE"
[[ $(grep -c -- '--mail-mode' "$FAKE_TABLE") == 1 ]]
cp "$FAKE_TABLE" "$temp/installed"
cp "$conf" "$temp/confirmed"
run $'\n\n\n'
grep -q 'managed schedule: real' "$temp/output"
cmp "$conf" "$temp/confirmed"
cmp "$FAKE_TABLE" "$temp/installed"
[[ $(wc -l < "$FAKE_TABLE.writes") == 1 && $(wc -l < "$MAIL_CALLS") == 2 ]]
# A live real schedule keeps its old recipient until the replacement is verified.
export TEST_RECIPIENT=replacement@example.test
run $'n\ny\ny\nreplacement@example.test\ny\ny\nn\nn\nn'
cmp "$conf" "$temp/confirmed"
cmp "$FAKE_TABLE" "$temp/installed"
run $'n\ny\ny\nreplacement@example.test\ny\ny\ny\ny\nn\nn'
grep -qx 'EMAIL_TO=replacement@example.test' "$conf"
cmp "$FAKE_TABLE" "$temp/installed"
cp "$conf" "$temp/replaced"
run $'n\ny\ny\nOFF\nn\nn\nn'
cmp "$conf" "$temp/replaced"
cmp "$FAKE_TABLE" "$temp/installed"
run $'n\ny\ny\nOFF\ny\nn\nn'
grep -qx 'EMAIL_TO=' "$conf"
grep -qx 'MAIL_ENABLED=0' "$conf"
grep -qx 'CPU_WARNING=70' "$conf"
grep -q 'Managed schedule: mock' "$temp/output"
bash "$repo/scripts/setup_cron.sh" --print > "$temp/mock-preview"
cat "$temp/before" "$temp/mock-preview" | cmp - "$FAKE_TABLE"
[[ $(wc -l < "$MAIL_CALLS") == 4 ]]
run $'n\nn\ny'
grep -q 'Managed schedule: none' "$temp/output"
cmp "$FAKE_TABLE" "$temp/before"
# An unavailable subject-capable mail client cannot trigger a send or change config.
printf '#!/bin/sh\nexit 7\n' > "$temp/bin/mailx"
cp "$conf" "$temp/disabled"
run $'n\ny\nperson@example.test\nn'
grep -q 'Email needs mailx' "$temp/output"
cmp "$conf" "$temp/disabled"
[[ $(wc -l < "$MAIL_CALLS") == 4 ]]
# Removing the ignore rule must prevent even soliciting a new address.
printf '*.log\n' > "$repo/.gitignore"
run $'n\ny\nn'
grep -q 'ignored, untracked' "$temp/output"
cmp "$conf" "$temp/disabled"
echo 'PASS wizard: fresh sample, private settings, invalid recipient, unconfigured transport, mock preview, single test submissions, confirmed real scheduling, repeat setup and crontab preservation'
