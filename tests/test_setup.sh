#!/usr/bin/env bash
set -euo pipefail
umask 077
# shellcheck source=tests/test_alerts.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/test_alerts.sh"
source_root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
sandbox
export FAKE_TABLE="$temp/table" MAIL_CALLS="$temp/mail-calls" WIZARD_ROOT="$repo" WIZARD_PIDFILE="$temp/wizard.pid"
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
if [[ $1 == -l ]]; then
    cat "$FAKE_TABLE"
else
    [[ ${TEST_CRON_WRITE_FAIL:-0} == 0 ]] || exit 73
    cp -- "$1" "$FAKE_TABLE"
    echo write >> "$FAKE_TABLE.writes"
fi
STUB
cat > "$temp/bin/mailx" <<'STUB'
#!/usr/bin/env bash
set -eu
if [[ $1 == --help ]]; then echo 'mailx -s subject'; exit; fi
[[ $# == 3 && $1 == -s && $3 == "${TEST_RECIPIENT:-person@example.test}" ]]
shopt -s nullglob
candidates=("$WIZARD_ROOT/config/".sysguard-*.log)
[[ ${#candidates[@]} == 1 && ! -L ${candidates[0]} && $(stat -c %a "${candidates[0]}") == 600 ]]
git -C "$WIZARD_ROOT" check-ignore -q -- "${candidates[0]}"
[[ -z $(git -C "$WIZARD_ROOT" ls-files -- "${candidates[0]}") ]]
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
    local expected=${2:-0} status=0
    # The child Bash expands its own PID before replacing itself with setup.
    # shellcheck disable=SC2016
    bash -c 'printf "%s\n" "$BASHPID" > "$WIZARD_PIDFILE"; exec bash "$1"' \
        sysguard "$repo/scripts/setup.sh" <<< "$1" > "$temp/output" 2>&1 || status=$?
    if [[ $status != "$expected" ]]; then
        printf 'wizard expected exit %s, got %s\n' "$expected" "$status" >&2
        cat "$temp/output" >&2
        exit 1
    fi
    [[ -z $(find "$repo/config" -name '.sysguard-*.log' -print -quit) ]]
    if grep -Eq 'person@example.test|replacement@example.test|unrelated-private-job' "$temp/output"; then echo 'private information in output' >&2; exit 1; fi
}
# Skipping everything on a fresh checkout does not create local state.
run ''
[[ ! -e $repo/data/metrics.csv && ! -e $repo/runtime && ! -e $repo/config/local.conf && ! -e $MAIL_CALLS ]]
cmp "$FAKE_TABLE" "$temp/before"
mv "$repo/config/defaults.conf" "$temp/shipped"
run '' 2
grep -Fq 'missing default config' "$temp/output"
mv "$temp/shipped" "$repo/config/defaults.conf"
run $'y\nn\ny\nn'
[[ -s $repo/data/metrics.csv && ! -e $repo/config/local.conf && ! -e $MAIL_CALLS ]]
cmp "$FAKE_TABLE" "$temp/before"
grep -q 'sample collected' "$temp/output"

# Arnav Nakka's reproduction: installing the default preview must never discard
# the same explicit override from four jobs.
(
    custom="$temp/custom settings.conf"
    printf '%s\n' REPORT_PDF_ENABLED=0 LOG_RETENTION_DAYS=90 MAIL_ENABLED=1 EMAIL_TO=person@example.test > "$custom"
    for mode in mock real; do
        options=()
        [[ $mode == mock ]] || options=(--mail-mode real)
        bash "$repo/scripts/setup_cron.sh" --install --config "$custom" "${options[@]}"
        [[ $(grep -Fc -- "$custom" "$FAKE_TABLE") == 4 ]]
        cp "$FAKE_TABLE" "$temp/expected-table"
        run $'n\nn\nn\ny\ny'
        cmp "$FAKE_TABLE" "$temp/expected-table" || {
            echo "Explicit override jobs after wizard: $(grep -Fc -- "$custom" "$FAKE_TABLE") of 4" >&2
            exit 1
        }
        if [[ $mode == real ]]; then
            run $'n\ny\nOFF\ny'
            grep -Fq 'scheduled email remains enabled' "$temp/output"
            cmp "$FAKE_TABLE" "$temp/expected-table"
            [[ ! -e $repo/config/local.conf && ! -e $MAIL_CALLS ]]
        fi
    done
    cp "$temp/before" "$FAKE_TABLE"
    rm -- "$FAKE_TABLE.writes"
)

conf=$repo/config/local.conf
# Configuration privacy is checked before the loader can read an override.
printf '%s\n' 'synthetic malformed outside file' > "$temp/outside-config"
ln -s "$temp/outside-config" "$conf"
run '' 2
grep -Fq 'owned, readable regular config/local.conf' "$temp/output"
if grep -Fq 'configuration could not be loaded' "$temp/output"; then
    echo 'Unsafe config reached the loader' >&2
    exit 1
fi
[[ -L $conf && ! -e $MAIL_CALLS ]]
unlink "$conf"
ln "$temp/outside-config" "$conf"
run '' 2
grep -Fq 'owned, readable regular config/local.conf' "$temp/output"
unlink "$conf"
mkfifo "$conf"
run '' 2
grep -Fq 'owned, readable regular config/local.conf' "$temp/output"
unlink "$conf"
printf '%s\n' MAIL_ENABLED=0 EMAIL_TO= > "$conf"
chmod 644 "$conf"
run '' 2
grep -Fq 'mode 0600 before retrying' "$temp/output"
[[ $(stat -c %a "$conf") == 644 ]]
chmod 600 "$conf"
printf '%s\n' UNKNOWN_KEY=1 > "$conf"
run '' 2
grep -Fq 'configuration could not be loaded or validated' "$temp/output"
cmp "$FAKE_TABLE" "$temp/before"
[[ ! -e $MAIL_CALLS ]]

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
# Keep the existing recipient and decline the proposed test submission.
run $'n\ny\nn\ny\nn\nn\nn'
cmp "$conf" "$temp/confirmed"
cmp "$FAKE_TABLE" "$temp/installed"
[[ $(wc -l < "$MAIL_CALLS") == 2 ]]

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
# Failed cron update must leave both config and schedule unchanged.
TEST_CRON_WRITE_FAIL=1 run $'n\ny\ny\nOFF\ny' 4
grep -Fq 'Schedule update failed. Local mail settings were preserved.' "$temp/output"
grep -Fq 'real schedule is still active' "$temp/output"
cmp "$conf" "$temp/replaced"
cmp "$FAKE_TABLE" "$temp/installed"

cat > "$temp/bin/mv" <<'STUB'
#!/usr/bin/env bash
if [[ ${@: -1} == */config/local.conf ]]; then
    case ${TEST_CONFIG_PUBLICATION:-} in
        fail) exit 72 ;;
        interrupt) kill -TERM "$(cat "$WIZARD_PIDFILE")"; exit 72 ;;
    esac
fi
exec /usr/bin/mv "$@"
STUB
chmod 700 "$temp/bin/mv"
bash "$repo/scripts/setup_cron.sh" --print > "$temp/mock-preview"
for publication in fail interrupt; do
    expected=72
    [[ $publication != interrupt ]] || expected=143
    TEST_CONFIG_PUBLICATION=$publication run $'n\ny\ny\nOFF\ny' "$expected"
    grep -Fq 'OFF incomplete: the schedule is mock, but local mail settings were not cleared.' "$temp/output"
    grep -Fq 'Rerun setup, select OFF' "$temp/output"
    cmp "$conf" "$temp/replaced"
    cat "$temp/before" "$temp/mock-preview" | cmp - "$FAKE_TABLE"
    [[ $(wc -l < "$MAIL_CALLS") == 4 ]]
    bash "$repo/scripts/setup_cron.sh" --install --mail-mode real
    cmp "$FAKE_TABLE" "$temp/installed"
done

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
run $'n\ny\nn' 2
grep -q 'ignored, untracked' "$temp/output"
cmp "$conf" "$temp/disabled"
echo 'PASS wizard: fresh and private setup, explicit approvals, recipient changes, OFF recovery, candidate cleanup and crontab preservation'
