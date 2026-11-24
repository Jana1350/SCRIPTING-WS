#!/usr/bin/env bash
set -uo pipefail
export LC_ALL=C TZ=Etc/UTC
umask 077
root=$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P && printf '.') || exit 4
root=${root%$'\n.'}
scripts=$root/scripts
config=$root/config/local.conf
work=$(mktemp -d) || exit 4
candidate=''
interrupted=0
use_color=0
if [[ -t 0 && -t 1 && -z ${NO_COLOR+x} && ${TERM:-dumb} != dumb ]] &&
    command -v tput >/dev/null && colors=$(tput colors 2>/dev/null) && [[ $colors =~ ^[0-9]+$ ]] &&
    (( colors >= 8 )); then
    use_color=1
fi

cleanup() {
    [[ -z $candidate ]] || rm -f -- "$candidate"
    rm -rf -- "$work"
}
trap cleanup EXIT
trap 'interrupted=1' INT
trap 'exit 129' HUP
trap 'exit 143' TERM

ask() {
    local answer
    printf '%s [y/N] ' "$1"
    IFS= read -r answer || return 2
    [[ ${answer,,} == y || ${answer,,} == yes ]]
}

notice() {
    local color=$1
    shift
    if (( use_color )); then printf '\033[%sm%s\033[0m\n' "$color" "$*"
    else printf '%s\n' "$*"; fi
}

result() {
    local color=31
    case $2 in 0) color=32 ;; 2|6) color=33 ;; esac
    notice "$color" "$1 finished (exit $2)."
    return "$2"
}

run() {
    local label=$1 rc=0
    shift
    "$@" || rc=$?
    result "$label" "$rc"
}

private_file() {
    local identity
    [[ -f $1 && ! -L $1 && -O $1 && -r $1 ]] || return 1
    identity=$(stat -c '%a:%h' -- "$1") || return 1
    [[ $identity == 600:1 || $identity == 400:1 ]]
}

ignored_untracked() {
    local tracked
    tracked=$(git -C "$root" ls-files -- "$1") || return 1
    [[ -z $tracked ]] && git -C "$root" check-ignore -q -- "$1"
}

private_config() {
    local mode
    if [[ -d $root/config && ! -L $root/config && -O $root/config &&
          -f $root/config/defaults.conf && ! -L $root/config/defaults.conf ]] &&
        mode=$(stat -c '%a' -- "$root/config") && (( (8#$mode & 022) == 0 )) &&
        ignored_untracked "$config" &&
        { [[ ! -e $config && ! -L $config ]] || private_file "$config"; }; then
        return 0
    fi
    printf '%s\n' 'Unsafe configuration path. Use an owned config directory and an ignored, untracked, singly linked local.conf with mode 0600 or 0400.' >&2
    return 2
}

load_settings() {
    private_config || return "$?"
    # shellcheck source=scripts/config.sh
    source "$scripts/config.sh" || return 7
    sysguard_config_load "$root" "${2-}" "$1"
}

cron_read() {
    local client=$1 table=$2 error=$3 rc=0 user
    "$client" -l > "$table" 2> "$error" || rc=$?
    (( rc != 0 )) || return 0
    user=$(id -un) || return 4
    [[ $rc == 1 && ! -s $table && $(cat "$error") == "no crontab for $user" ]]
}

cron_split() {
    local table=$1 block=$2 outside=$3
    : > "$block" || return 4
    if [[ -s $table ]]; then
        [[ $(tail -c 1 "$table" | wc -l) == 1 ]] &&
            cmp -s "$table" <(tr -d '\000' < "$table") || return 4
    fi
    awk -v block="$block" '
        $0 == "# BEGIN SysGuard System Health Monitor v1" {
            if (inside || seen) exit 4
            inside=seen=1; print > block; next
        }
        $0 == "# END SysGuard System Health Monitor v1" {
            if (!inside) exit 4
            print > block; inside=0; next
        }
        inside { print > block; next }
        { print }
        END { if (inside) exit 4 }
    ' "$table" > "$outside"
}

make_templates() {
    local path line suffix escaped rc=0
    [[ -d $root/config && ! -L $root/config &&
       -f $root/config/defaults.conf && ! -L $root/config/defaults.conf ]] || return 4
    path=$root/config/defaults.conf
    bash "$scripts/setup_cron.sh" --print --config "$path" > "$work/render" 2> "$work/template-error" || rc=$?
    if (( rc )); then cat "$work/template-error" >&2; return "$rc"; fi
    escaped=${path//\'/\'\\\'\'}
    suffix=" '--config' '$escaped'"
    while IFS= read -r line; do
        printf '%s\n' "${line%"$suffix"}"
    done < "$work/render" > "$work/mock" || return 4
    # The real schedule adds precisely these two words to the first job.
    # This comparison template never changes or submits a crontab.
    sed "2s/\$/ '--mail-mode' 'real'/" "$work/mock" > "$work/real"
}

matches_schedule() {
    local mode=$1 owner=$2 line suffix first='' i
    local -a installed template
    mapfile -t installed < "$work/block"
    mapfile -t template < "$work/$mode"
    [[ ${#installed[@]} == 6 && ${#template[@]} == 6 ]] || return 1
    local explicit_pattern="^ '--config' '(/[^']*)'$"
    for i in 1 2 3 4; do
        line=${template[i]//"$root"/"$owner"}
        [[ ${installed[i]} == "$line"* ]] || return 1
        suffix=${installed[i]#"$line"}
        [[ -z $suffix || $suffix =~ $explicit_pattern ]] || return 1
        if (( i == 1 )); then first=$suffix; fi
        [[ $first == "$suffix" ]] || return 1
    done
    cron_mode=$mode
    cron_explicit=0 cron_override=''
    if [[ $first =~ $explicit_pattern ]]; then
        cron_explicit=1 cron_override=${BASH_REMATCH[1]}
    fi
}

inspect_cron() {
    local owner mode monitor_line
    local owner_pattern=" sysguard '(/[^']*)/scripts/setup_cron.sh' "
    cron_state=unknown cron_owner='' cron_mode=unknown cron_explicit=0 cron_override=''
    cron_client=$(type -P crontab) || { cron_state=unavailable; return 0; }
    cron_read "$cron_client" "$work/table" "$work/error" &&
        cron_split "$work/table" "$work/block" "$work/outside" || return 0
    if [[ ! -s $work/block ]]; then cron_state=none; return 0; fi
    make_templates || return 0
    monitor_line=$(sed -n '2p' "$work/block") || return 0
    owner=$root
    for mode in mock real; do
        if matches_schedule "$mode" "$owner"; then
            cron_state=owned cron_owner=$root
            return 0
        fi
    done
    if [[ $monitor_line =~ $owner_pattern && ${BASH_REMATCH[1]} != "$root" ]]; then
        owner=${BASH_REMATCH[1]}
        for mode in mock real; do
            if matches_schedule "$mode" "$owner"; then
                cron_state=foreign cron_owner=$owner
                return 0
            fi
        done
    fi
}

describe_cron() {
    case $cron_state in
        none) printf '%s\n' 'Managed schedule: absent.' ;;
        unavailable) printf '%s\n' 'crontab is unavailable. Managed scheduling cannot be verified.' ;;
        owned|foreign)
            printf 'Managed schedule owner: %s (%s), scheduled delivery: %s' "$cron_owner" "$cron_state" "$cron_mode"
            if (( cron_explicit )); then printf ' (explicit config)'; fi
            printf '.\n' ;;
        *) printf '%s\n' 'Managed schedule ownership and delivery cannot be verified.' ;;
    esac
}

# Exported only to the setup/installer child. Read the table normally and
# constrain writes to the exact inspected table and the local generated blocks.
crontab() {
    if [[ -z $SG_CRON_CLIENT ]]; then printf '%s\n' 'crontab unavailable.' >&2; return 7; fi
    if [[ $# == 1 && $1 == -l ]]; then "$SG_CRON_CLIENT" -l; return "$?"; fi
    if [[ $# == 1 && -f $1 && ! -L $1 ]] &&
        cron_read "$SG_CRON_CLIENT" "$SG_CRON_WORK/current" "$SG_CRON_WORK/error" &&
        cmp -s "$SG_CRON_WORK/expected" "$SG_CRON_WORK/current" &&
        cron_split "$1" "$SG_CRON_WORK/next-block" "$SG_CRON_WORK/next-outside" &&
        cmp -s "$SG_CRON_WORK/outside" "$SG_CRON_WORK/next-outside" &&
        { [[ ! -s $SG_CRON_WORK/next-block ]] ||
          { [[ $SG_CRON_INSTALL == 1 ]] &&
            { cmp -s "$SG_CRON_WORK/mock" "$SG_CRON_WORK/next-block" ||
              cmp -s "$SG_CRON_WORK/real" "$SG_CRON_WORK/next-block"; }; }; } &&
        cron_read "$SG_CRON_CLIENT" "$SG_CRON_WORK/current" "$SG_CRON_WORK/error" &&
        cmp -s "$SG_CRON_WORK/expected" "$SG_CRON_WORK/current"; then
        "$SG_CRON_CLIENT" "$1" || return "$?"
        cron_read "$SG_CRON_CLIENT" "$SG_CRON_WORK/current" "$SG_CRON_WORK/error" &&
            cmp -s "$1" "$SG_CRON_WORK/current" &&
            cp -- "$SG_CRON_WORK/current" "$SG_CRON_WORK/expected" && return 0
        printf '%s\n' 'Cron write could not be verified. Inspect the installed schedule.' >&2
        return 4
    fi
    printf '%s\n' 'Cron write refused: the inspected table changed or the proposed edit is unsafe.' >&2
    return 4
}

cron_guard_ready() {
    make_templates || return "$?"
    cp -- "$work/table" "$work/expected" || return 4
}

utc_schedule() {
    case $(env -u TZ date '+%Z %z') in
        'UTC +0000'|'GMT +0000') ;;
        *) return 1 ;;
    esac
    ! grep -Eq '^[[:space:]]*(CRON_TZ|TZ)[[:space:]]*=' "$work/outside"
}

with_cron_guard() (
    export SG_CRON_CLIENT=$cron_client SG_CRON_WORK=$work SG_CRON_INSTALL=$1
    shift
    export -f cron_read cron_split crontab
    "$@"
)

daemon_status() {
    local status=''
    if command -v systemctl >/dev/null; then status=$(systemctl is-active cron 2>/dev/null) || :; fi
    if [[ $status == active ]] || pgrep -x cron >/dev/null 2>&1; then
        printf 'active'
    elif [[ $status == inactive || $status == failed ]]; then
        printf '%s' "$status"
    else
        printf 'unverified'
    fi
}

start_monitoring() {
    local -A settings=()
    local -a args=()
    local rc=0
    inspect_cron
    describe_cron
    if [[ $cron_state != none && $cron_state != owned ]] || (( cron_explicit )); then
        printf '%s\n' 'Installation refused. Review the existing schedule and its config in the owning checkout.'
        return 4
    fi
    if ! utc_schedule; then
        printf '%s\n' 'Installation refused. UTC daemon time without a crontab timezone override is required.'
        return 2
    fi
    load_settings settings || { result 'Configuration validation' "$?"; return; }
    printf 'Cron daemon: %s.\n' "$(daemon_status)"
    printf '%s\n' 'The proposed schedule uses mock alerts unless you approve real delivery.'
    if [[ ${settings[MAIL_ENABLED]} == 1 ]] && ask 'Use real email for scheduled alerts?'; then
        if ! scheduled_mail_client; then return 7; fi
        args=(--mail-mode real)
    fi
    bash "$scripts/setup_cron.sh" --print "${args[@]}" || { result 'Schedule preview' "$?"; return; }
    ask 'Install this schedule?' || { printf 'Installation declined.\n'; return 0; }
    cron_guard_ready || { result 'Cron guard' "$?"; return; }
    with_cron_guard 1 bash "$scripts/setup_cron.sh" --install "${args[@]}" || rc=$?
    result 'Schedule installation' "$rc"
}

stop_monitoring() {
    local rc=0
    inspect_cron
    describe_cron
    if [[ $cron_state != owned ]]; then
        printf '%s\n' 'Removal refused. This checkout must own the managed schedule.'
        return 4
    fi
    ask 'Remove the managed schedule for this checkout?' || { printf 'Removal declined.\n'; return 0; }
    cron_guard_ready || { result 'Cron guard' "$?"; return; }
    with_cron_guard 0 bash "$scripts/setup_cron.sh" --uninstall || rc=$?
    result 'Schedule removal' "$rc"
}

setup_wizard() {
    local allow_install=0 rc=0
    private_config || return "$?"
    inspect_cron
    if [[ $cron_state == foreign ]]; then
        describe_cron
        notice 33 'Wizard skipped to protect the current crontab. The existing installation remains active.'
        printf '%s\n' "These settings apply only to this checkout. Change the active installation's settings from its own checkout."
        if ask 'Open local recipient and threshold settings?'; then email_menu local; fi
        return 0
    fi
    if [[ $cron_state == unknown ]]; then
        describe_cron
        printf '%s\n' 'Wizard skipped to protect the current crontab. Use the local settings and monitoring menus.'
        return 4
    fi
    if [[ $cron_state == unavailable ]]; then
        with_cron_guard 0 bash "$scripts/setup.sh" || rc=$?
        result 'Setup wizard' "$rc"
        return "$?"
    fi
    if (( cron_explicit )); then
        describe_cron
        printf '%s\n' 'Wizard skipped to preserve explicit settings. The configured schedule is still in effect.'
        return 4
    fi
    cron_guard_ready || { result 'Cron guard' "$?"; return; }
    if utc_schedule; then allow_install=1
    else printf '%s\n' 'The wizard can check configuration, but schedule installation requires UTC.'; fi
    printf '%s\n' 'The existing wizard may offer a setup email and cron changes. Approve each only if intended.'
    with_cron_guard "$allow_install" bash "$scripts/setup.sh" || rc=$?
    result 'Setup wizard' "$rc"
}

scheduled_mail_client() {
    local usage
    if ! env PATH=/usr/bin:/bin sh -c 'command -v mailx' >/dev/null; then
        printf '%s\n' 'Real scheduling needs mailx on /usr/bin:/bin. See the SMTP setup in README.md.' >&2
        return 7
    fi
    mkdir -p "$work/mail-help-home" || return 4
    usage=$(env -i PATH=/usr/bin:/bin HOME="$work/mail-help-home" LC_ALL=C sh -c 'mailx --help' </dev/null 2>&1) || :
    if [[ ! $usage =~ (^|[[:space:][:punct:]])-s([[:space:]=,]|$) ]]; then
        printf '%s\n' 'Real scheduling needs mailx with subject support. See the SMTP setup in README.md.' >&2
        return 7
    fi
    printf '%s\n' 'mailx is available on the cron PATH. Configure the existing outgoing transport separately. Inbox delivery is unverified.'
}

switch_off_schedule() {
    inspect_cron
    case $cron_state in
        unknown)
            printf '%s\n' 'Scheduled delivery cannot be verified. Review the crontab before turning email off.'
            return 4 ;;
        foreign)
            describe_cron
            printf '%s\n' 'Use the owning checkout to change its delivery settings.'
            return 4 ;;
    esac
    [[ $cron_state == owned && $cron_mode == real ]] || return 0
    if (( cron_explicit )); then
        printf '%s\n' 'The explicit real schedule remains enabled. Switch it to mock using its original config, or stop it first.'
        return 4
    fi
    bash "$scripts/setup_cron.sh" --print || return "$?"
    cron_guard_ready || return "$?"
    with_cron_guard 1 bash "$scripts/setup_cron.sh" --install
}

# Keep the writer and the wizard on the same advisory lock. The staged copy
# stays private in the config directory so publication is an atomic rename.
edit_config() (
    local operation=$1 key line source=/dev/null rc=0 lock switched=0
    shift
    # The shared loader writes these arrays by name.
    # shellcheck disable=SC2034
    local -A current=() checked=() changes=()
    local -a keys=()
    trap '[[ -z $candidate ]] || rm -f -- "$candidate"' EXIT
    exec {lock}<"$root" || return 4
    flock -n -E 6 "$lock" || return "$?"
    if [[ $operation != off ]]; then
        inspect_cron
        if (( cron_explicit )) && [[ $cron_override == "$config" || $cron_override -ef $config ]]; then
            printf '%s\n' 'This private file is used by an explicit schedule. Its settings were preserved.'
            return 4
        fi
    fi
    load_settings current || { result 'Configuration validation' "$?"; return; }
    if [[ $operation == enable && -z ${current[EMAIL_TO]} ]]; then
        printf '%s\n' 'Configure a recipient first.' >&2
        return 2
    fi
    while (( $# )); do
        keys+=("$1")
        changes[$1]=$2
        shift 2
    done
    if [[ -f $config ]]; then
        cp -- "$config" "$work/config-before" || return 4
        source=$work/config-before
    fi
    candidate=$(mktemp "$root/config/.sysguard-XXXXXXXX.log") || return 4
    private_file "$candidate" && ignored_untracked "$candidate" || return 4
    {
        while IFS= read -r line || [[ -n $line ]]; do
            key=${line%%=*}
            if [[ $key =~ ^[A-Z_]+$ && ${changes[$key]+set} ]]; then continue; fi
            printf '%s\n' "$line" || return 4
        done < "$source"
        for key in "${keys[@]}"; do printf '%s=%s\n' "$key" "${changes[$key]}" || return 4; done
    } > "$candidate" || return 4
    sysguard_config_load "$root" "$candidate" checked || { result 'Candidate configuration validation' "$?"; return; }
    if [[ $operation == off ]]; then
        ask 'Disable local mail, clear its recipient, and switch an owned real schedule to mock?' || return 0
        # The existing cron installer must acquire the checkout lock itself.
        flock -u "$lock" || return 4
        switch_off_schedule || { result 'Scheduled mail change' "$?"; return; }
        switched=1
        if ! flock -n "$lock"; then
            printf '%s\n' 'Local settings were preserved. A schedule may already have switched to mock. Review it before retrying.'
            return 6
        fi
        inspect_cron
        if [[ $cron_state == foreign || $cron_state == unknown ||
              ( $cron_state == owned && $cron_mode == real ) ]]; then
            printf '%s\n' 'Cron changed during the update. Local settings were preserved. Review scheduled mail before retrying.'
            return 6
        fi
    elif [[ $operation == local-off ]]; then
        ask 'Disable mail and clear the recipient for this checkout?' || return 0
    elif [[ $operation == enable ]]; then
        ask 'Enable real email in the private config? Scheduled real delivery still requires explicit real mode.' || return 0
    else
        ask 'Save these private settings? Any active schedule using local settings will pick up the change.' || return 0
    fi
    if ! private_config ||
        { [[ $source == /dev/null ]] && [[ -e $config || -L $config ]]; } ||
        { [[ $source != /dev/null ]] && ! cmp -s "$source" "$config"; } ||
        ! private_file "$candidate" || ! ignored_untracked "$candidate"; then
        rc=4
    elif ! mv -T -- "$candidate" "$config"; then
        rc=4
    else
        candidate=''
    fi
    if (( rc )); then
        if (( switched )); then printf '%s\n' 'Local settings were preserved. The schedule may already be mock. Review it before retrying.'; fi
        return "$rc"
    fi
    if [[ $operation == off ]]; then
        printf '%s\n' 'Local email disabled and recipient cleared.'
        if [[ $cron_state == unavailable ]]; then printf '%s\n' 'Scheduled delivery could not be verified.'; fi
    else
        printf '%s\n' 'Private settings saved. Cron configuration was not edited.'
    fi
)

email_help() {
    printf '%s\n' 'Recipient settings belong to this checkout. The existing SMTP sender is configured outside SysGuard.'
}

change_recipient() {
    local recipient
    email_help
    printf 'Recipient address (hidden, Enter to cancel): '
    IFS= read -rs recipient || return 0
    printf '\n'
    [[ -n $recipient ]] || return 0
    edit_config recipient EMAIL_TO "$recipient"
}

set_threshold() {
    local metric=$1 warning critical
    printf '%s warning (Enter to cancel): ' "$metric"
    IFS= read -r warning && [[ -n $warning ]] || return 0
    printf '%s critical (Enter to cancel): ' "$metric"
    IFS= read -r critical && [[ -n $critical ]] || return 0
    if [[ ! $warning =~ ^[0-9]+$ || ! $critical =~ ^[0-9]+$ ]]; then
        printf 'Thresholds must be decimal integers.\n' >&2
        return 2
    fi
    edit_config threshold "${metric}_WARNING" "$warning" "${metric}_CRITICAL" "$critical"
}

reset_thresholds() {
    local -A defaults=()
    load_settings defaults "$root/config/defaults.conf" || return "$?"
    edit_config threshold CPU_WARNING "${defaults[CPU_WARNING]}" CPU_CRITICAL "${defaults[CPU_CRITICAL]}" \
        MEMORY_WARNING "${defaults[MEMORY_WARNING]}" MEMORY_CRITICAL "${defaults[MEMORY_CRITICAL]}" \
        DISK_WARNING "${defaults[DISK_WARNING]}" DISK_CRITICAL "${defaults[DISK_CRITICAL]}"
}

email_menu() {
    local choice rc scope=${1-}
    email_help
    while :; do
        cat <<'MENU'

Email and alert settings
1. Configure or change recipient
2. Enable real email alerts
3. Disable real email alerts
4. Configure CPU warning and critical thresholds
5. Configure memory warning and critical thresholds
6. Configure disk warning and critical thresholds
7. Restore default thresholds
0. Return
MENU
        if [[ $scope == local ]]; then
            printf '%s\n' 'All changes in this menu are local. The foreign schedule stays unchanged.'
        fi
        choose || return 0
        choice=$selection rc=0
        case $choice in
            1) change_recipient || rc=$? ;;
            2) scheduled_mail_client && edit_config enable MAIL_ENABLED 1 || rc=$? ;;
            3)
                if [[ $scope == local ]]; then edit_config local-off MAIL_ENABLED 0 EMAIL_TO '' || rc=$?
                else edit_config off MAIL_ENABLED 0 EMAIL_TO '' || rc=$?; fi ;;
            4) set_threshold CPU || rc=$? ;;
            5) set_threshold MEMORY || rc=$? ;;
            6) set_threshold DISK || rc=$? ;;
            7) reset_thresholds || rc=$? ;;
            0) return 0 ;;
            *) invalid_choice; continue ;;
        esac
        result 'Settings operation' "$rc"
    done
}

read_measurement() {
    local line=$1 remainder
    IFS=, read -r sample_stamp sample_cpu sample_memory sample_disk remainder <<< "$line"
    [[ $sample_stamp =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}$ &&
       $sample_cpu =~ ^[0-9]+\.[0-9]$ && $sample_memory =~ ^[0-9]+\.[0-9]$ &&
       $sample_disk =~ ^[0-9]+\.[0-9]$ && -z $remainder ]]
}

show_measurement() {
    printf 'Timestamp: %s (offset %s)\nCPU: %s%% | Memory: %s%% | Disk: %s%%\n' \
        "$sample_stamp" "${sample_stamp: -6}" "$sample_cpu" "$sample_memory" "$sample_disk"
}

latest_measurement() {
    local file=$1 line
    [[ -f $file && -r $file && ! -L $file ]] || return 1
    line=$(tail -n 1 -- "$file") && read_measurement "$line"
}

monitor_now() {
    local data=$root/data rc=0 line='' mode=mock ledger submitted
    local -A settings=()
    local -a mail_args=()
    load_settings settings || { result 'Configuration validation' "$?"; return; }
    if [[ ${settings[MAIL_ENABLED]} == 1 ]]; then
        printf '%s\n' 'Real mode submits email only for qualifying new alert transitions. Saved transitions are not replayed.'
        if ask 'Allow real email processing for this sample? No uses mock'; then
            mode=real
            mail_args=(--mail-mode real)
        elif (( $? == 2 )); then
            printf '\n%s\n' 'Monitoring cancelled.'
            return 0
        fi
    fi
    inspect_cron
    if [[ $mode == mock ]]; then
        if [[ ${settings[MAIL_ENABLED]} == 1 || $cron_state == unknown || $cron_state == unavailable ||
              ( $cron_state == owned && ( $cron_mode == real || $cron_explicit == 1 ) ) ]]; then
            data=$root/data/manual
        fi
    elif [[ $cron_state != owned || $cron_mode != real || $cron_explicit == 1 ]]; then
        data=$root/data/manual-real
    fi
    if [[ $data != "$root/data" ]]; then
        printf 'Using a separate manual sample history for %s mode: %s\n' "$mode" "$data"
    fi
    bash "$scripts/main.sh" --once --data-dir "$data" "${mail_args[@]}" > "$work/collection" || rc=$?
    line=$(tail -n 1 -- "$work/collection")
    if read_measurement "$line"; then
        show_measurement
        if grep -Fxq -- "$line" "$data/metrics.csv"; then
            printf 'Sample saved: %s\n' "$data/metrics.csv"
        else
            printf '%s\n' 'The collector emitted a row. Its presence in the active CSV could not be verified.'
        fi
    else
        printf '%s\n' 'No new sample was confirmed.'
        if [[ -s $work/collection ]]; then cat "$work/collection"; fi
    fi
    if (( rc == 5 )); then
        notice 31 "Alert delivery or capture failed in $mode mode. Check the diagnostic and delivery records."
    elif (( rc != 0 )); then
        notice 31 'Monitoring or alert processing did not complete. See the diagnostic above.'
    elif [[ $mode == mock ]]; then
        printf '%s\n' 'Alert processing completed in mock mode.'
    else
        ledger=$data/alerts/delivery.csv
        printf '%s\n' 'Alert processing completed in real mode.'
        if [[ -n $sample_stamp && -f $ledger && ! -L $ledger ]] &&
            submitted=$(awk -F, -v stamp="$sample_stamp" '$1 == stamp && $4 == "submitted" {n++} END {print n+0}' "$ledger") &&
            (( submitted )); then
            printf 'The delivery ledger records %s submission(s) accepted by mailx for this timestamp. Check the inbox separately.\n' "$submitted"
        else
            printf '%s\n' 'No transport submission was confirmed for this sample. A sample without a qualifying transition sends nothing.'
        fi
    fi
    result 'Monitor now' "$rc"
}

follow_samples() (
    trap 'exit 0' INT TERM
    local previous=''
    printf '%s\n' 'Reading saved measurements. Ctrl+C returns to the menu. Background monitoring continues.'
    while :; do
        if latest_measurement "$root/data/metrics.csv"; then
            if [[ $previous != "$sample_stamp" ]]; then show_measurement; previous=$sample_stamp; fi
        elif [[ -z $previous ]]; then
            printf '%s\n' 'Waiting for a saved sample...'
            previous=waiting
        fi
        sleep 2 || return "$?"
    done
)

live_monitoring() {
    local -A settings=()
    local sampled now daemon
    load_settings settings || { result 'Configuration validation' "$?"; return; }
    inspect_cron
    daemon=$(daemon_status)
    if [[ $cron_state == unknown ||
          ( $cron_state == owned && $daemon != inactive && $daemon != failed ) ]] ||
        { latest_measurement "$root/data/metrics.csv" &&
          sampled=$(date -d "$sample_stamp" +%s) && now=$(date +%s) &&
          (( sampled <= now && now - sampled <= settings[MAX_DATA_AGE_SECONDS] )); }; then
        follow_samples
    else
        printf '%s\n' 'Foreground sampling. Ctrl+C stops this view. Background cron jobs are unaffected.'
        printf '%s\n' timestamp,cpu_percent,memory_percent,disk_percent
        run 'Foreground monitor' bash "$scripts/monitor.sh" --watch
    fi
}

report_directory() {
    [[ -d $root/reports && ! -L $root/reports &&
       -d $root/reports/$1 && ! -L $root/reports/$1 ]]
}

report_file() {
    local file=$1 directory=$2 name=${1##*/}
    report_directory "$directory" && [[ $file == "$root/reports/$directory/$name" &&
        -f $file && -r $file && ! -L $file ]]
}

pdf_file() {
    local header name=${1##*/}
    local day='[0-9]{4}-[0-9]{2}-[0-9]{2}' pattern
    pattern="^${day}\.pdf$"
    if [[ $2 == weekly ]]; then pattern="^${day}_to_${day}\.pdf$"; fi
    [[ $name =~ $pattern ]] && report_file "$1" "$2" &&
        IFS= read -r -n 5 header < "$1" && [[ $header == '%PDF-' ]] &&
        pdfinfo "$1" >/dev/null 2>&1
}

open_path() {
    local path=$1 windows_path encoded command rc=0 attempted=1
    if [[ ${WSL_INTEROP-} ]] && command -v powershell.exe >/dev/null &&
        command -v wslpath >/dev/null && command -v base64 >/dev/null; then
        if windows_path=$(wslpath -w "$path") && [[ -n $windows_path ]] &&
            encoded=$(printf '%s' "$windows_path" | base64 -w0); then
            # Send the path as data so spaces, quotes and PowerShell operators
            # cannot change the command. Exit 0 means Windows accepted the request.
            printf -v command "try { \$p = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('%s')); Invoke-Item -LiteralPath \$p -ErrorAction Stop; exit 0 } catch { [Console]::Error.WriteLine(\$_.Exception.Message); exit 1 }" "$encoded"
            powershell.exe -NoProfile -NonInteractive -Command "$command" || rc=$?
        else
            printf '%s\n' 'Could not convert the path for a Windows opener.' >&2
            rc=4
        fi
    elif [[ ${WSL_INTEROP-} ]] && command -v wslview >/dev/null; then
        wslview "$path" || rc=$?
    elif command -v xdg-open >/dev/null; then
        xdg-open "$path" || rc=$?
    elif command -v gio >/dev/null; then
        gio open "$path" || rc=$?
    else
        rc=7 attempted=0
        notice 33 'No graphical opener is available.'
    fi
    if (( rc == 0 )); then
        printf 'Opener accepted: %s\n' "$path"
    else
        if (( attempted )); then notice 31 "Opener failed (exit $rc)."; fi
        printf 'Path: %s\n' "$path"
        if [[ ${WSL_INTEROP-} ]] && command -v wslpath >/dev/null; then
            printf "Fallback (WSL): explorer.exe \"\$(wslpath -w %q)\"\n" "$path"
            if windows_path=$(wslpath -w "$path") && [[ -n $windows_path ]]; then
                printf 'Windows Explorer address: %s\n' "$windows_path"
            fi
        else
            printf 'Fallback (Linux desktop): xdg-open %q\n' "$path"
        fi
    fi
    return "$rc"
}

offer_pdf() {
    local file=$1 period=$2 day
    if ! pdf_file "$file" "$period"; then
        printf 'PDF missing or invalid: %s\n' "$file"
        return 4
    fi
    if ask "Open $file?"; then
        pdf_file "$file" "$period" || { printf 'PDF changed before opening.\n'; return 4; }
        if [[ $period == today ]]; then
            day=$(date -u +%F) || return 4
            if [[ ${file##*/} != "$day.pdf" ]]; then
                notice 33 "The UTC date changed. Use Generate Reports (6 -> 1) to generate today's report."
                return 4
            fi
        fi
        open_path "$file"
    fi
}

generate_report() {
    local period=$1 rc=0 line html='' pdf='' name chart
    private_config || return "$?"
    bash "$scripts/report.sh" "$period" > "$work/report-output" || rc=$?
    cat "$work/report-output"
    result "$period report" "$rc" || return "$?"
    while IFS= read -r line; do
        case $line in
            'Wrote '*.html) html=${line#Wrote } ;;
            'Wrote '*.pdf) pdf=${line#Wrote } ;;
        esac
    done < "$work/report-output"
    if ! report_file "$html" "$period"; then
        printf '%s\n' 'The expected HTML artifact could not be verified.'
        return 4
    fi
    name=${html##*/}
    printf 'Report period (UTC): %s\n' "${name%.html}"
    if grep -Fq '<h2>NO DATA</h2>' "$html"; then
        notice 33 'NO DATA: the report succeeded but the period contains no valid samples.'
    fi
    if chart=$(sed -n 's/.*<img src="\.\.\/charts\/\([A-Za-z0-9_-]*\.png\)".*/\1/p' "$html") &&
        [[ -n $chart ]] && report_file "$root/reports/charts/$chart" charts; then
        printf 'Chart: %s\n' "$root/reports/charts/$chart"
    fi
    if [[ -n $pdf ]]; then offer_pdf "$pdf" "$period"
    else printf '%s\n' 'This run did not publish a PDF.'; fi
}

report_menu() {
    while :; do
        cat <<'MENU'

Generate reports
1. Generate today's report
2. Generate previous day's report
3. Generate previous week's report
4. Generate daily and weekly reports
0. Return
MENU
        choose || return 0
        case $selection in
            1) generate_report today ;;
            2) generate_report daily ;;
            3) generate_report weekly ;;
            4) generate_report daily; generate_report weekly ;;
            0) return 0 ;;
            *) invalid_choice ;;
        esac
    done
}

missing_report() {
    notice 33 "$1"
    printf '%s\n' 'Use Generate Reports (6) to create a report.'
    if ask 'Go to Generate Reports?'; then report_menu; fi
}

latest_pdf() {
    local period=$1 file latest='' day
    local -A settings=()
    if ! command -v pdfinfo >/dev/null; then
        printf 'PDF verification needs pdfinfo. Folder: %s\n' "$root/reports/$period"
        return 7
    fi
    if load_settings settings && [[ ${settings[REPORT_PDF_ENABLED]} == 0 ]]; then
        printf '%s\n' 'PDF generation is disabled. Existing PDFs are still available.'
    fi
    if [[ $period == today ]]; then
        day=$(date -u +%F) || return 4
        file=$root/reports/today/$day.pdf
        if pdf_file "$file" "$period"; then offer_pdf "$file" "$period"
        else missing_report "No current-day PDF is available for $day (UTC). Generate today's report with 6 -> 1."; fi
        return
    fi
    for file in "$root/reports/$period/"*.pdf; do
        if pdf_file "$file" "$period"; then latest=$file; fi
    done
    if [[ -z $latest ]]; then
        missing_report "No verified $period PDF was found in $root/reports/$period."
        return 0
    fi
    offer_pdf "$latest" "$period"
}

open_folder() {
    local path=$root/reports/$1
    if ! report_directory "$1"; then
        missing_report "The $1 report folder is unavailable: $path"
    elif ask "Open $path?"; then
        report_directory "$1" && open_path "$path"
    fi
}

browse_artifacts() {
    local file directory item
    local -a paths=()
    for file in "$root/reports/"{today,daily,weekly}/*.html "$root/reports/charts/"*.png; do
        directory=${file%/*}
        directory=${directory##*/}
        if report_file "$file" "$directory"; then paths+=("$file"); fi
    done
    if (( ${#paths[@]} == 0 )); then missing_report 'No HTML reports or PNG charts found.'; return 0; fi
    for item in "${!paths[@]}"; do printf '%d. %s\n' "$((item+1))" "${paths[item]}"; done
    printf '%s\n' '0. Return'
    choose || return 0
    if [[ $selection == 0 ]]; then return 0; fi
    if [[ $selection =~ ^[1-9][0-9]{0,8}$ ]] && (( selection <= ${#paths[@]} )); then
        file=${paths[selection-1]}
        directory=${file%/*}
        if ask "Open $file?"; then report_file "$file" "${directory##*/}" && open_path "$file"; fi
    else
        invalid_choice
    fi
}

view_menu() {
    while :; do
        cat <<'MENU'

View reports and charts
1. Open today's PDF (UTC)
2. Open latest daily PDF
3. Open latest weekly PDF
4. Open partial reports folder
5. Open daily reports folder
6. Open weekly reports folder
7. View available HTML reports and PNG charts
0. Return
MENU
        choose || return 0
        case $selection in
            1) latest_pdf today ;;
            2) latest_pdf daily ;;
            3) latest_pdf weekly ;;
            4) open_folder today ;;
            5) open_folder daily ;;
            6) open_folder weekly ;;
            7) browse_artifacts ;;
            0) return 0 ;;
            *) invalid_choice ;;
        esac
    done
}

count_files() {
    local file total=0
    for file; do
        if [[ -f $file && ! -L $file ]]; then ((total+=1)); fi
    done
    printf '%s' "$total"
}

list_archives() {
    local file found=0
    for file in "$root/data/archive"/metrics-*.csv.gz; do
        if [[ -f $file && ! -L $file ]]; then printf '%s\n' "$file"; found=1; fi
    done
    if (( ! found )); then printf '%s\n' 'No historical gzip archives found.'; fi
}

history_menu() {
    while :; do
        cat <<'MENU'

Historical data and archives
1. View recent stored measurements
2. List historical gzip archives
3. Preview retention
4. Perform historical rotation
0. Return
MENU
        choose || return 0
        case $selection in
            1)
                if latest_measurement "$root/data/metrics.csv"; then tail -n 10 -- "$root/data/metrics.csv"
                else printf '%s\n' 'No readable measurements are available.'; fi ;;
            2) list_archives ;;
            3)
                if private_config; then run 'Retention preview' bash "$scripts/rotate_logs.sh" --dry-run; fi ;;
            4)
                if private_config &&
                    ask 'Archive completed UTC dates? Current-day rows are kept and retention remains preview-only?'; then
                    run 'Rotation' bash "$scripts/rotate_logs.sh"
                fi ;;
            0) return 0 ;;
            *) invalid_choice ;;
        esac
    done
}

system_status() {
    local rev rc=0
    local -A settings=()
    rev=$(git -C "$root" rev-parse HEAD 2>/dev/null) || rev=unverified
    printf 'Checkout: %s\nRevision: %s\nCron daemon: %s\n' "$root" "$rev" "$(daemon_status)"
    printf 'Launcher timezone: %s. Host cron timezone: %s.\n' "$(date '+%Z %z')" "$(env -u TZ date '+%Z %z')"
    load_settings settings || rc=$?
    if (( rc == 0 )); then
        printf 'Configuration: valid. Effective local mail enablement: %s.\n' "${settings[MAIL_ENABLED]}"
    else
        printf 'Configuration could not be validated (exit %s).\n' "$rc"
    fi
    inspect_cron
    describe_cron
    if latest_measurement "$root/data/metrics.csv"; then show_measurement
    else printf '%s\n' 'Latest measurement unavailable.'; fi
    printf 'Today HTML/PDF: %s/%s | Daily HTML/PDF: %s/%s | Weekly HTML/PDF: %s/%s | PNG charts: %s | Gzip archives: %s\n' \
        "$(count_files "$root/reports/today/"*.html)" "$(count_files "$root/reports/today/"*.pdf)" \
        "$(count_files "$root/reports/daily/"*.html)" "$(count_files "$root/reports/daily/"*.pdf)" \
        "$(count_files "$root/reports/weekly/"*.html)" "$(count_files "$root/reports/weekly/"*.pdf)" \
        "$(count_files "$root/reports/charts/"*.png)" "$(count_files "$root/data/archive/"metrics-*.csv.gz)"
    transport_status
}

transport_status() {
    local mail transport=''
    mail=$(type -P mailx) || mail=''
    if [[ -x /usr/sbin/sendmail ]]; then transport=/usr/sbin/sendmail
    else transport=$(type -P msmtp) || transport=''; fi
    printf 'Mail client: %s | Local transport: %s\n' "${mail:-unavailable}" "${transport:-not detected}"
    printf '%s\n' 'Executable checks only. SMTP account setup and inbox receipt need separate verification. See README.md.'
}

dependencies() {
    local tool path output rc
    for tool in bash git awk date df flock gzip stat sync crontab systemctl mailx msmtp gnuplot weasyprint file pdfinfo pdfimages pdftotext python3 shellcheck; do
        if ! path=$(type -P "$tool"); then printf '%s: unavailable\n' "$tool"; continue; fi
        case $tool in
            mailx|msmtp) printf '%s: %s (version not queried)\n' "$tool" "$path"; continue ;;
            pdfinfo|pdfimages|pdftotext) output=$("$path" -v 2>&1); rc=$? ;;
            crontab) printf '%s: %s\n' "$tool" "$path"; continue ;;
            *) output=$("$path" --version 2>&1); rc=$? ;;
        esac
        printf '%s: %s | %s (version exit %s)\n' "$tool" "$path" "${output%%$'\n'*}" "$rc"
    done
    printf 'Cron daemon: %s.\n' "$(daemon_status)"
    transport_status
}

diagnostics_menu() {
    while :; do
        cat <<'MENU'

Diagnostics and testing
1. Check dependencies and versions
2. Run the seven release regression suites
0. Return
MENU
        choose || return 0
        case $selection in
            1) dependencies ;;
            2) if ask 'Run the isolated release regression suites now?'; then run 'Regression suites' bash "$root/tests/run_all.sh"; fi ;;
            0) return 0 ;;
            *) invalid_choice ;;
        esac
    done
}

choose() {
    printf 'Choice: '
    IFS= read -r selection
}

invalid_choice() { notice 33 'Enter a listed number.'; }

show_menu() {
    printf '\n%s\n' '------------------------------------------------------------'
    notice 36 'SysGuard | Terminal Control Center'
    if latest_measurement "$root/data/metrics.csv"; then
        printf 'Latest saved sample: %s | CPU %s%% | Memory %s%% | Disk %s%%\n' \
            "$sample_stamp" "$sample_cpu" "$sample_memory" "$sample_disk"
    else
        printf '%s\n' 'No saved sample in the main history for this checkout.'
    fi
    printf '%s\n' '------------------------------------------------------------'

    notice 36 'CONFIGURATION'
    cat <<'MENU'
 1. Setup and configuration
 5. Email and alert settings
MENU
    notice 36 'REPORTS AND STORAGE'
    cat <<'MENU'
 6. Generate reports
 7. View reports and charts
 8. Historical data and archives
MENU
    notice 36 'SYSTEM MANAGEMENT'
    cat <<'MENU'
 2. Start automatic monitoring
 3. Monitor system now
 4. Live monitoring
 9. System status
10. Stop automatic monitoring
11. Diagnostics and testing
 0. Exit
MENU
}

while :; do
    interrupted=0
    show_menu
    if ! choose; then
        printf '\n'
        if (( interrupted )); then continue; fi
        break
    fi
    rc=0
    case $selection in
        1) setup_wizard ;;
        2) start_monitoring ;;
        3) monitor_now ;;
        4) live_monitoring ;;
        5) email_menu ;;
        6) report_menu ;;
        7) view_menu ;;
        8) history_menu ;;
        9) system_status ;;
        10) stop_monitoring ;;
        11) diagnostics_menu ;;
        0) break ;;
        *) invalid_choice ;;
    esac || rc=$?
    if (( rc )); then printf 'Menu action returned exit %s.\n' "$rc"; fi
done
printf 'SysGuard closed.\n'
