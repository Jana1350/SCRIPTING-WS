#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
umask 077
# shellcheck source=scripts/alerts.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/alerts.sh"
trap 'die 4 "cron setup failed at line $LINENO"' ERR
repo_root
action='' config=''
declare -A cfg=()
while (($#)); do
    case $1 in
        --help) echo 'setup_cron.sh [--print|--install|--uninstall] [--config FILE]'; exit 0;;
        --print|--install|--uninstall) [[ -z $action ]] || die 2 "choose one action"; action=$1;;
        --config) [[ -n ${2-} && $2 != --* ]] || die 2 "missing config"; config=$(absolute "$2"); shift;;
        *) die 2 "unexpected argument";;
    esac
    shift
done
action=${action:---print}
begin='# BEGIN SysGuard System Health Monitor v1'
end='# END SysGuard System Health Monitor v1'
quote() {
    # Single-quoted POSIX shell word, also suitable for crond's outer shell.
    printf "'%s'" "${1//\'/\'\\\'\'}"
}
job() {
    local schedule=$1 script=$2 lock_mode=$3 cmd path
    shift 3
    path=$(quote "$root/scripts/$script")
    cmd="$path"
    for arg in "$@"; do cmd+=" $(quote "$arg")"; done
    if [[ -n $config ]]; then cmd+=" --config $(quote "$config")"; fi
    local log lock wrapper
    log=$(quote "$root/runtime/cron.log")
    lock=$(quote "$root/runtime/cron.lock")
    wrapper="umask 077; log=$log; if [[ -f \$log && \$(wc -c < \"\$log\") -ge 1048576 ]]; then mv -f -- \"\$log\" \"\$log.1\" || exit 4; fi; exec $cmd >>\"\$log\" 2>&1"
    printf '%s /usr/bin/env SHELL=/bin/bash PATH=/usr/bin:/bin /usr/bin/flock %s %s /bin/bash -c %s\n' \
        "$schedule" "$lock_mode" "$lock" "$(quote "$wrapper")"
}
render() {
    printf '%s\n' "$begin"
    job '* * * * *' main.sh -n --once
    job '10 0 * * *' report.sh -x daily
    job '20 0 * * 1' report.sh -x weekly
    job '30 0 * * *' rotate_logs.sh -x
    printf '%s\n' "$end"
}
if [[ $action != --uninstall ]]; then
    [[ $root$config != *%* && ! $root$config =~ [[:cntrl:]] ]] || die 2 "path unsafe for cron"
    if [[ $action == --install || -n $config || -e $root/config/defaults.conf ]]; then load_config "$config"; fi
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
