#!/usr/bin/env bash
set -eu -o pipefail
export LC_ALL=C
umask 077
scripts=$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/alerts.sh
source "$scripts/alerts.sh"
repo_root
user=$(id -un)
local_conf=$root/config/local.conf
declare -A cfg=()
work=$(mktemp -d)
candidate=''
off_switch_pending=0
cleanup() {
    if (( off_switch_pending )); then
        case $(schedule_mode) in
            mock)
                if ! private_path || ! cmp -s "$work/verified" "$local_conf"; then
                    echo 'OFF incomplete: the schedule is mock, but local mail settings were not cleared. Rerun setup, select OFF, and confirm clearing the recipient.' >&2
                fi
                ;;
            real)
                echo 'OFF incomplete: the real schedule is still active. Review the crontab and retry OFF before relying on email being disabled.' >&2
                ;;
            *)
                echo 'OFF incomplete: schedule state is uncertain. Review the crontab before retrying OFF.' >&2
                ;;
        esac
    fi
    [[ -z $candidate ]] || rm -f -- "$candidate"
    rm -rf -- "$work"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
ask() {
    local answer
    printf '%s [y/N] ' "$1" >&2
    IFS= read -r answer && [[ ${answer,,} == y || ${answer,,} == yes ]]
}

schedule_mode() {
    local result rc
    if ! command -v crontab >/dev/null; then echo unavailable; return; fi
    if result=$(crontab -l 2>"$work/cron-error" | awk '
        $0 == "# BEGIN SysGuard System Health Monitor v1" { starts++; inside=1; next }
        $0 == "# END SysGuard System Health Monitor v1" { if (!inside) bad=1; inside=0; ends++; next }
        inside && index($0, "\047--config\047") { explicit=1 }
        inside && /\047monitor\047 \047cron-monitor.lock\047/ {
            monitors++; real = index($0, "\047--mail-mode\047 \047real\047") != 0
        }
        END {
            if (!starts && !ends) print "none"
            else if (bad || inside || starts!=1 || ends!=1 || monitors!=1) print "unknown"
            else if (explicit) print (real ? "explicit-real" : "explicit-mock")
            else print (real ? "real" : "mock")
        }'); then echo "$result"
    else
        rc=$?
        if [[ $rc == 1 && $(cat "$work/cron-error") == "no crontab for $user" ]]; then echo none
        else echo unknown; fi
    fi
}

# Keep personal settings out of Git, including the temporary publication file.
ignored_untracked() {
    local tracked
    tracked=$(git -C "$root" ls-files -- "$1") || return 1
    [[ -z $tracked ]] && git -C "$root" check-ignore -q -- "$1"
}

private_file() {
    local permissions
    [[ -f $1 && ! -L $1 && -O $1 && -r $1 ]] || return 1
    permissions=$(stat -c '%a:%h' -- "$1") || return 1
    [[ $permissions == 600:1 || $permissions == 400:1 ]]
}

private_path() {
    local mode
    if [[ ! -d $root/config || -L $root/config || ! -O $root/config ]]; then
        echo 'Use a regular config directory owned by the current Linux user.' >&2
        return 1
    fi
    mode=$(stat -c '%a' -- "$root/config") || return 1
    if (( (8#$mode & 022) != 0 )); then
        echo 'Remove group and other write permissions from the config directory.' >&2
        return 1
    fi
    if [[ -L $root/config/defaults.conf ]]; then
        echo 'Restore config/defaults.conf as a regular file from the checkout.' >&2
        return 1
    fi
    if ! ignored_untracked "$local_conf"; then
        echo 'Email setup needs an ignored, untracked config/local.conf.' >&2
        return 1
    fi
    if [[ -e $local_conf || -L $local_conf ]] && ! private_file "$local_conf"; then
        echo 'Use an owned, readable regular config/local.conf with one link. Replace a symlink or unsupported file. For an owned regular file with one link, set mode 0600 before retrying.' >&2
        return 1
    fi
}

prepare_email() {
    local recipient client scheduled_client mode line status enabled=1
    local -a validation=(--mail-mode real)
    # Coordinate with other wizards and the managed crontab writer.
    if ! flock -n 9; then echo 'Another setup is in progress. Try email setup again later.'; return; fi
    mode=$(schedule_mode)
    if [[ $mode == explicit-* ]]; then
        echo 'An explicit schedule config controls delivery. Local email setup skipped.'
        if [[ $mode == explicit-real ]]; then echo 'OFF did not run: scheduled email remains enabled.'; fi
        return 0
    fi
    if [[ $mode == unknown ]]; then echo 'Cannot verify the current schedule. Email settings preserved.'; return; fi
    # Reload under the setup lock before choosing or reusing a recipient.
    private_path || return 2
    load_config ""
    recipient=${cfg[EMAIL_TO]}
    if [[ $mode == real && ${cfg[MAIL_ENABLED]} != 1 ]]; then
        echo 'Remove the existing real schedule before enabling local mail.'; return
    fi
    if [[ -z $recipient ]] || ask 'Change the existing recipient?'; then
        printf 'Recipient address (hidden; enter OFF for no recipient, or press Enter to cancel): ' >&2
        IFS= read -rs recipient || return 0
        printf '\n' >&2
    fi
    [[ -n $recipient ]] || { echo 'Recipient required. Email setup skipped.'; return; }
    if [[ $recipient == OFF ]]; then
        enabled=0; recipient=''; validation=()
    fi
    candidate=$(mktemp -- "$root/config/.sysguard-XXXXXXXX.log")
    if ! private_file "$candidate" || ! ignored_untracked "$candidate"; then
        echo 'Temporary config must be private, ignored and untracked. Email setup skipped.' >&2
        return 2
    fi
    local input=/dev/null
    if [[ -f $local_conf ]]; then cp -- "$local_conf" "$work/original"; input=$work/original; fi
    # Pass input as data, without awk escape processing or a command-line address.
    while IFS= read -r line || [[ -n $line ]]; do
        case $line in MAIL_ENABLED=*|EMAIL_TO=*) continue;; esac
        printf '%s\n' "$line"
    done < "$input" > "$candidate"
    printf 'MAIL_ENABLED=%s\nEMAIL_TO=%s\n' "$enabled" "$recipient" >> "$candidate"
    if ! "$scripts/setup_cron.sh" --print --config "$candidate" "${validation[@]}" >/dev/null 2>&1; then
        echo 'Invalid recipient or configuration. Personal settings preserved.'; return
    fi
    if [[ $mode == real ]]; then
        # Only manage a real schedule using this checkout and its default local override.
        if ! crontab -l | awk '/^# BEGIN SysGuard System Health Monitor v1$/{block=1} block; /^# END SysGuard System Health Monitor v1$/{block=0}' |
            cmp -s - <("$scripts/setup_cron.sh" --print --mail-mode real); then
            echo 'The active schedule uses different settings. Personal settings preserved.'; return
        fi
    fi
    if (( enabled )); then
        scheduled_client=$(env PATH=/usr/bin:/bin sh -c 'command -v mailx' || :)
        if [[ $mode == real && -z $scheduled_client ]]; then
            echo 'The active schedule needs mailx on /usr/bin:/bin. Recipient preserved.'; return
        fi
        client=${scheduled_client:-$(type -P mailx || :)}
        if [[ -z $client ]] || ! (PATH=${client%/*}:$PATH; mailx_supports_subject); then
            echo 'Email needs mailx with subject support. See the Ubuntu/Gmail setup in README.md.'; return
        fi
        email='mail executable available; delivery unverified'
        if ! command -v msmtp >/dev/null && [[ ! -x /usr/sbin/sendmail ]]; then
            echo 'No local sendmail or msmtp detected. A directly configured mailx SMTP route can also work.'
        fi
        if ! ask 'Is outgoing mail configured for this Linux user?'; then
            echo 'Configure the mail transport using README.md, then rerun setup.'; return
        fi
        ask 'Send one SysGuard setup test email now?' || return 0
        if ! printf '%s\n' 'Your SysGuard setup test.' | "$client" -s 'SysGuard setup test' "$recipient" >/dev/null 2>&1; then
            email='test submission failed'; return
        fi
        email='test submitted; inbox unconfirmed'
        ask 'Did you receive the SysGuard setup test in the intended inbox?' || return 0
        email='inbox confirmed'
        if [[ $mode == real && $recipient != "${cfg[EMAIL_TO]}" ]]; then
            ask 'Use this verified inbox for future scheduled alerts?' || return 0
        fi
    else
        if [[ $mode == real ]]; then
            "$scripts/setup_cron.sh" --print || return 1
            ask 'Switch this schedule to mock delivery and clear its recipient?' || return 0
            # The installer acquires this same directory lock itself.
            off_switch_pending=1
            flock -u 9
            "$scripts/setup_cron.sh" --install || {
                status=$?
                echo 'Schedule update failed. Local mail settings were preserved.' >&2
                return "$status"
            }
            if ! flock -n 9 || [[ $(schedule_mode) != mock ]]; then
                echo 'Schedule changed during setup. Local mail settings were preserved.' >&2
                return 6
            fi
            current=mock
        else
            ask 'Clear the local recipient and disable email alerts?' || return 0
        fi
    fi
    if ! private_path || { [[ -f $work/original ]] && ! cmp -s "$work/original" "$local_conf"; } ||
        { [[ ! -f $work/original ]] && [[ -e $local_conf ]]; }; then
        echo 'Local settings changed during setup. Rerun to save the verified settings.' >&2
        return 4
    fi
    if ! private_file "$candidate" || ! ignored_untracked "$candidate"; then
        echo 'Temporary config changed during setup. Local mail settings were preserved.' >&2
        return 4
    fi
    cp -- "$candidate" "$work/verified"
    mv -T -- "$candidate" "$local_conf"
    candidate=''
    off_switch_pending=0
    if (( ! enabled )); then email="disabled; no recipient"
    elif [[ -n $scheduled_client ]]; then real_ready=1
    else echo 'Scheduled mail needs mailx on /usr/bin:/bin.'; fi
}

private_path || exit 2
load_config ""

os=$(awk -F= '$1=="PRETTY_NAME" {gsub(/"/,"",$2);print $2}' /etc/os-release)
[[ $(uname -r) != *[Mm]icrosoft* ]] || os+=" (WSL)"
zone=$(env -u TZ date '+%Z %z')
daemon=stopped
if systemctl is-active --quiet cron 2>/dev/null || pgrep -x cron >/dev/null 2>&1; then daemon=running; fi
current=$(schedule_mode)
printf 'Checkout: %s\nLinux user and cron owner: %s\nEnvironment: %s\nLocal time zone: %s\nCron: %s; managed schedule: %s\n' "$root" "$user" "$os" "$zone" "$daemon" "$current"
if (( EUID == 0 )); then echo 'Running as root. Any installed jobs will run as root.'; fi
monitor='check skipped'
email='inbox verification skipped'
real_ready=0
if ask 'Collect one mock-mode sample? Writes data/metrics.csv, alert state and any transition records under data/alerts/, plus runtime locks.'; then
    if "$scripts/main.sh" --once; then monitor='sample collected and alerts processed'
    else monitor="check failed (exit $?)"; fi
fi
if ask 'Set up and verify personal email alerts?'; then prepare_email 9<"$root"; fi

schedule=$current
if [[ $current == mock || $current == real ]] && ask "Remove the current $current SysGuard schedule for $user?"; then
    if "$scripts/setup_cron.sh" --uninstall; then schedule=$(schedule_mode)
    else schedule="$(schedule_mode) (removal failed)"; fi
elif [[ $current == explicit-* ]]; then
    echo 'Preserved the explicit-config schedule. To change it, use setup_cron.sh with the original --config FILE.'
elif [[ $daemon != running || $current == unavailable ]]; then
    echo 'Scheduling needs the Ubuntu cron package and a running cron daemon. Check systemctl status cron.'
elif [[ $current == unknown ]]; then
    echo 'Cannot safely identify the managed schedule. Check your crontab before making changes.'
elif ask "Preview a schedule for $user?"; then
    for tool in gzip gnuplot; do
        # shellcheck disable=SC2016 # $1 belongs to the child shell.
        env PATH=/usr/bin:/bin sh -c 'command -v "$1"' sh "$tool" >/dev/null || echo "Scheduled reports or rotation need $tool on the cron PATH."
    done
    if [[ ${cfg[REPORT_PDF_ENABLED]} == 1 ]]; then
        for tool in weasyprint file pdfinfo pdfimages; do
            # shellcheck disable=SC2016 # $1 belongs to the child shell.
            env PATH=/usr/bin:/bin sh -c 'command -v "$1"' sh "$tool" >/dev/null || echo "Scheduled PDF reports need $tool on the cron PATH."
        done
    fi
    options=()
    proposed=mock
    if (( real_ready )) && ask 'Use confirmed real email for scheduled monitoring?'; then
        proposed=real; options=(--mail-mode real)
    fi
    printf 'Preview for %s | %s | %s mail | log: %s/runtime/cron.log\n' "$user" "$zone" "$proposed" "$root"
    if "$scripts/setup_cron.sh" --print "${options[@]}" &&
        ask "Install this $proposed schedule for $user (current: $current)?"; then
        if [[ $proposed == real ]] && ! cmp -s "$work/verified" "$local_conf"; then
            echo 'Verified mail settings changed. Rerun setup before scheduling real mail.'
            schedule=$(schedule_mode)
        elif [[ $(schedule_mode) != "$current" ]]; then
            echo 'The managed schedule changed during setup. Review it again.'
            schedule=$(schedule_mode)
        elif "$scripts/setup_cron.sh" --install "${options[@]}"; then schedule=$(schedule_mode)
        else schedule="$(schedule_mode) (installation failed)"; fi
    fi
fi
printf '\nMonitoring: %s\nEmail: %s\nManaged schedule: %s\nNext: bash scripts/main.sh --status\n' "$monitor" "$email" "$schedule"
