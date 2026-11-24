#!/usr/bin/env bash
# Generated crontab entries source only this runner in a fresh Bash process.
run_scheduled() (
    umask 077
    local runtime=$1 name=$2 lock=$3 status log=$1/cron.log
    shift 3
    # Serialize the size check and rename across both job groups.
    exec 7<"$runtime" || exit 4
    flock -w 2 7 || { echo "$name skipped: cron log lock busy" >> "$log"; exit 6; }
    if [[ -f $log && $(wc -c < "$log") -ge 1048576 ]]; then
        mv -f -- "$log" "$log.1" || { echo "$name failed: log rotation" >> "$log"; exit 4; }
    fi
    exec 7<&-
    exec 8>>"$runtime/$lock" || { echo "$name failed: cannot open $lock" >> "$log"; exit 4; }
    flock -n -E 6 8 || {
        status=$?
        if (( status == 6 )); then echo "$name skipped: $lock busy" >> "$log"
        else echo "$name failed: flock exit $status" >> "$log"; fi
        exit "$status"
    }
    "$@" >> "$log" 2>&1 && exit 0
    status=$?
    if (( status == 6 )); then echo "$name skipped: command reported lock contention (exit 6)" >> "$log"
    else echo "$name failed: command exit $status" >> "$log"; fi
    exit "$status"
)
if [[ ${BASH_SOURCE[0]} != "$0" ]]; then return 0; fi
set -Eeuo pipefail
export LC_ALL=C
umask 077
script_dir=${BASH_SOURCE[0]%/*}
[[ $script_dir != "${BASH_SOURCE[0]}" ]] || script_dir=.
# shellcheck source=scripts/alerts.sh
source "$script_dir/alerts.sh"
trap 'die 4 "cron setup failed at line $LINENO"' ERR
repo_root
action='' config=''
monitor_options=(--once)
mail_mode=''
declare -A cfg=()
while (($#)); do
    case $1 in
        --help)
            printf '%s\n' 'setup_cron.sh [--print|--install] [--config FILE] [--mail-mode real]' \
                'setup_cron.sh --uninstall [--config FILE]' \
                'Uninstall accepts --config for compatibility and skips configuration loading.'
            exit 0
            ;;
        --print|--install|--uninstall) [[ -z $action ]] || die 2 "choose one action"; action=$1;;
        --config)
            [[ -n ${2-} && $2 != --* ]] || die 2 "missing config"
            [[ $2 != *%* && ! $2 =~ [[:cntrl:]] ]] || die 2 "path unsafe for cron"
            config=$2
            [[ $config == /* ]] || config=$root/$config
            shift
            ;;
        --mail-mode)
            [[ ${2-} == real && -z $mail_mode ]] || die 2 "expected a single --mail-mode real"
            mail_mode=real
            shift
            ;;
        *) die 2 "unexpected argument";;
    esac
    shift
done
action=${action:---print}
[[ $action != --uninstall || -z $mail_mode ]] || die 2 "--mail-mode real requires --print or --install"
begin='# BEGIN SysGuard System Health Monitor v1'
end='# END SysGuard System Health Monitor v1'
quote() {
    # Single-quoted POSIX shell word, also suitable for crond's outer shell.
    printf "'%s'" "${1//\'/\'\\\'\'}"
}
job() {
    local schedule=$1 name=$2 lock=$3 script=$4 arg
    shift 4
    local -a args=("$root/scripts/setup_cron.sh" "$root/runtime" "$name" "$lock" "$root/scripts/$script" "$@")
    if [[ -n $config ]]; then args+=(--config "$config"); fi
    # The scheduled Bash process expands its own positional parameters.
    # shellcheck disable=SC2016
    printf '%s /usr/bin/env SHELL=/bin/bash PATH=/usr/bin:/bin /bin/bash -c %s sysguard' \
        "$schedule" "$(quote 'source "$1" || exit 4; shift; run_scheduled "$@"')"
    for arg in "${args[@]}"; do printf ' %s' "$(quote "$arg")"; done
    printf '\n'
}
render() {
    printf '%s\n' "$begin"
    job '* * * * *' monitor cron-monitor.lock main.sh "${monitor_options[@]}"
    job '10 0 * * *' daily-report cron-maintenance.lock report.sh daily
    job '20 0 * * 1' weekly-report cron-maintenance.lock report.sh weekly
    job '30 0 * * *' rotation cron-maintenance.lock rotate_logs.sh
    printf '%s\n' "$end"
}
if [[ $action != --uninstall ]]; then
    [[ $root$config != *%* && ! $root$config =~ [[:cntrl:]] ]] || die 2 "path unsafe for cron"
    if [[ $mail_mode == real ]]; then require_default_config; fi
    if [[ $action == --install || -n $mail_mode || -n $config || -e $root/config/defaults.conf ]]; then
        load_config "$config"
    fi
    if [[ $mail_mode == real ]]; then
        [[ ${cfg[MAIL_ENABLED]} == 1 ]] || die 2 "real mail requires MAIL_ENABLED=1"
        monitor_options+=(--mail-mode real)
    fi
fi
if [[ $action == --print ]]; then render; exit 0; fi
command -v crontab >/dev/null || die 7 "crontab missing"
command -v flock >/dev/null || die 7 "flock missing"
exec 8<"$root"
flock -n 8 || die 6 "cron setup busy"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
read_table() {
    local dest=$1 rc
    if crontab -l > "$dest" 2>"$tmp/error"; then return 0; else rc=$?; fi
    if [[ $rc == 1 && ! -s $dest && $(cat "$tmp/error") == "no crontab for $(id -un)" ]]; then return 0; fi
    die 4 "cannot read current crontab"
}
read_table "$tmp/original"
if [[ -s $tmp/original ]]; then
    last=$(tail -c 1 "$tmp/original" | od -An -tu1)
    [[ ${last// /} == 10 ]] || die 4 "unterminated crontab"
    cmp -s "$tmp/original" <(tr -d '\000' < "$tmp/original") || die 4 "binary crontab"
fi
if [[ $action == --install ]]; then
    for script in main.sh report.sh rotate_logs.sh; do
        [[ -f $root/scripts/$script && -x $root/scripts/$script ]] || die 7 "missing executable scripts/$script"
    done
    render > "$tmp/block"
else
    : > "$tmp/block"
fi
awk -v begin="$begin" -v end="$end" -v block="$tmp/block" '
    function insert(   line) { while ((getline line < block) > 0) print line; close(block) }
    $0 == begin { if (inside || seen) exit 2; inside=seen=1; insert(); next }
    $0 == end { if (!inside) exit 2; inside=0; next }
    !inside { print }
    END { if (inside) exit 2; if (!seen) insert() }
' "$tmp/original" > "$tmp/next" || die 4 "malformed managed markers"
if cmp -s "$tmp/original" "$tmp/next"; then exit 0; fi
if [[ $action == --install ]]; then mkdir -p -- "$root/runtime"; fi
read_table "$tmp/latest"
cmp -s "$tmp/original" "$tmp/latest" || die 6 "crontab changed during edit"
crontab "$tmp/next" || die 4 "crontab update failed"
