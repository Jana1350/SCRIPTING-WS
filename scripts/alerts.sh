#!/usr/bin/env bash
# Configuration and repository discovery are also used by setup_cron.sh.
die() { printf 'sysguard: %s\n' "$2" >&2; exit "$1"; }
absolute() { case $1 in /*) printf '%s\n' "$1";; *) printf '%s/%s\n' "$root" "$1";; esac; }
repo_root() {
    local dir=${BASH_SOURCE[0]%/*}
    [[ $dir != "${BASH_SOURCE[0]}" ]] || dir=.
    [[ -d $dir ]] || die 4 "script directory"
    # Keep trailing newlines in the path. Remove only Git's terminator and the sentinel.
    root=$(git -C "$dir" rev-parse --show-toplevel && printf '.') || die 7 "Git checkout required"
    root=${root%$'\n.'}
}
read_config() {
    local file=$1 line key value
    local -A seen=()
    [[ -f $file && -r $file ]] || die 2 "unreadable config: $file"
    cmp -s "$file" <(tr -d '\000' < "$file") || die 2 "binary config"
    while IFS= read -r line || [[ -n $line ]]; do
        [[ -z $line || $line == '#'* ]] && continue
        [[ $line =~ ^([A-Z_]+)=(.*)$ ]] || die 2 "invalid config line"
        key=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]}
        case $key in
            CPU_WARNING|CPU_CRITICAL|MEMORY_WARNING|MEMORY_CRITICAL|DISK_WARNING|DISK_CRITICAL|ALERT_HYSTERESIS_PERCENT|EMAIL_TO|MAIL_ENABLED|DISK_MOUNT|CPU_SAMPLE_SECONDS|WATCH_INTERVAL_SECONDS|MAX_DATA_AGE_SECONDS|LOG_RETENTION_DAYS|REPORT_PDF_ENABLED) ;;
            *) die 2 "unknown config key";;
        esac
        [[ ! ${seen[$key]+x} && ! $value =~ [[:cntrl:]] ]] || die 2 "duplicate key or control character"
        [[ $value != *['$`;&|<>()']* ]] || die 2 "invalid config value"
        seen[$key]=1
        cfg[$key]=$value
    done < "$file"
    printf 'sysguard: loaded %s\n' "$file" >&2
}
require_default_config() {
    [[ -f $root/config/defaults.conf ]] || die 2 "missing default config"
}
load_config() {
    local file=$1 key metric w c
    if [[ -n $file ]]; then
        [[ $file == /* ]] || file=$root/$file
        [[ ! $file =~ [[:cntrl:]] ]] || die 2 "invalid config path"
        if [[ -f $root/config/defaults.conf && $file != "$root/config/defaults.conf" ]]; then
            read_config "$root/config/defaults.conf"
        fi
        read_config "$file"
    else
        read_config "$root/config/defaults.conf"
        if [[ -e $root/config/local.conf || -L $root/config/local.conf ]]; then
            read_config "$root/config/local.conf"
        fi
    fi
    for key in CPU_WARNING CPU_CRITICAL MEMORY_WARNING MEMORY_CRITICAL DISK_WARNING DISK_CRITICAL ALERT_HYSTERESIS_PERCENT CPU_SAMPLE_SECONDS WATCH_INTERVAL_SECONDS MAX_DATA_AGE_SECONDS LOG_RETENTION_DAYS; do
        [[ ${cfg[$key]-} =~ ^[0-9]{1,9}$ ]] || die 2 "invalid $key"
        cfg[$key]=$((10#${cfg[$key]}))
    done
    for metric in CPU MEMORY DISK; do
        w=${cfg[${metric}_WARNING]} c=${cfg[${metric}_CRITICAL]}
        (( w < c && c <= 100 && cfg[ALERT_HYSTERESIS_PERCENT] <= 20 &&
           (cfg[ALERT_HYSTERESIS_PERCENT] == 0 || cfg[ALERT_HYSTERESIS_PERCENT] < w) )) || die 2 "invalid thresholds"
    done
    (( cfg[CPU_SAMPLE_SECONDS] > 0 && cfg[WATCH_INTERVAL_SECONDS] > cfg[CPU_SAMPLE_SECONDS] &&
       cfg[MAX_DATA_AGE_SECONDS] >= cfg[WATCH_INTERVAL_SECONDS]+cfg[CPU_SAMPLE_SECONDS] &&
       cfg[LOG_RETENTION_DAYS] > 0 )) || die 2 "invalid intervals"
    [[ ${cfg[MAIL_ENABLED]-} =~ ^[01]$ && ${cfg[REPORT_PDF_ENABLED]-} =~ ^[01]$ ]] || die 2 "invalid boolean"
    [[ ${cfg[DISK_MOUNT]-} =~ ^/[[:alnum:]_./[:blank:]-]*$ && -d ${cfg[DISK_MOUNT]} && -x ${cfg[DISK_MOUNT]} ]] || die 2 "invalid disk mount"
    local local_part='[A-Za-z0-9][A-Za-z0-9_+-]*(\.[A-Za-z0-9_+-]+)*'
    local domain='[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+'
    local address="^${local_part}@${domain}$"
    [[ ${cfg[EMAIL_TO]+x} ]] || die 2 "missing EMAIL_TO"
    if [[ -n ${cfg[EMAIL_TO]} || ${cfg[MAIL_ENABLED]} == 1 ]]; then
        [[ ${cfg[EMAIL_TO]} =~ $address ]] || die 2 "invalid recipient"
    fi
}
instant() {
    local stamp=$1
    [[ $stamp =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9][+-]([01][0-9]|2[0-3]):[0-5][0-9]$ ]] &&
        date -d "$stamp" +%s 2>/dev/null
}
tenths() {
    local value=$1
    [[ $value =~ ^[0-9]+\.[0-9]$ ]] || return 1
    value=${value//./}
    value=${value#"${value%%[!0]*}"}
    value=${value:-0}
    (( ${#value} <= 4 && value <= 1000 )) || return 1
    printf '%d\n' "$value"
}
read_sample() {
    local csv=$data/metrics.csv last p number end now
    [[ -e $csv ]] || die 3 "missing metrics"
    [[ -f $csv && -r $csv ]] || die 4 "metrics unreadable"
    head -n 1 -- "$csv" > "$tmp/header"
    printf '%s\n' 'timestamp,cpu_percent,memory_percent,disk_percent' | cmp -s - "$tmp/header" || die 3 "invalid header"
    tail -n 1 -- "$csv" > "$tmp/sample"
    end=$(tail -c 1 "$tmp/sample" | od -An -tu1)
    [[ ${end// /} == 10 ]] || die 3 "incomplete sample"
    cmp -s "$tmp/sample" <(tr -d '\000' < "$tmp/sample") || die 3 "binary sample"
    IFS= read -r last < "$tmp/sample"
    [[ $last =~ ^([^,]+),([^,]+),([^,]+),([^,]+)$ ]] || die 3 "invalid sample fields"
    stamp=${BASH_REMATCH[1]}
    values=("${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}")
    for p in "${values[@]}"; do
        number=$(tenths "$p") || die 3 "invalid percentage"
        numbers+=("$number")
    done
    epoch=$(instant "$stamp") || die 3 "invalid timestamp"
    now=$(date +%s)
    (( epoch <= now && now-epoch <= cfg[MAX_DATA_AGE_SECONDS] )) || die 3 "future or stale sample"
}
# Under the alert lock, replay any interrupted publication before accepting another sample.
publish() {
    local name
    for name in events.csv state.tsv; do
        if [[ -f $out/pending/$name ]]; then mv -T -- "$out/pending/$name" "$out/$name"; fi
    done
    rmdir -- "$out/pending"
}
read_state() {
    local metric ts level value line saved_epoch='' saved_stamp='' count=0
    local row=$'^([^\t]+)\t([^\t]+)\t(NORMAL|WARNING|CRITICAL)\t([^\t]+)$'
    [[ -f $out/state.tsv ]] || { [[ ! -e $out/events.csv && ! -e $out/delivery.csv ]] || die 4 "missing state"; return 0; }
    cmp -s "$out/state.tsv" <(tr -d '\000' < "$out/state.tsv") || die 4 "corrupt state"
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line =~ $row ]] || die 4 "corrupt state"
        metric=${BASH_REMATCH[1]} ts=${BASH_REMATCH[2]} level=${BASH_REMATCH[3]} value=${BASH_REMATCH[4]}
        [[ $metric == "${metrics[count]-}" ]] || die 4 "corrupt state order"
        tenths "$value" >/dev/null || die 4 "corrupt state value"
        if (( count == 0 )); then saved_epoch=$(instant "$ts") || die 4 "corrupt state timestamp"; saved_stamp=$ts; fi
        [[ $ts == "$saved_stamp" ]] || die 4 "inconsistent state"
        previous+=("$level")
        saved+=("$value")
        (( count+=1 ))
    done < "$out/state.tsv"
    (( count == 3 )) || die 4 "incomplete state"
    (( epoch >= saved_epoch )) || die 3 "out-of-order sample"
    if (( epoch == saved_epoch )); then
        [[ ${values[*]} == "${saved[*]}" ]] || die 3 "conflicting sample at same instant"
        exit 0
    fi
}
classify() {
    local metric=${1^^} old=$2 n=$3 w c h
    w=${cfg[${metric}_WARNING]} c=${cfg[${metric}_CRITICAL]} h=${cfg[ALERT_HYSTERESIS_PERCENT]}
    if (( n >= 10*c )); then level=CRITICAL
    elif [[ $old == CRITICAL ]] && (( n >= 10*(c-h) )); then level=CRITICAL
    elif (( n >= 10*w )); then level=WARNING
    elif [[ $old != NORMAL ]] && (( n >= 10*(w-h) )); then level=WARNING
    else level=NORMAL
    fi
    case "$old/$level" in
        */CRITICAL) threshold=$c reason=escalation;;
        CRITICAL/*) threshold=$((c-h)) reason=downgrade;;
        */NORMAL) threshold=$((w-h)) reason=recovery;;
        *) threshold=$w reason=escalation;;
    esac
    [[ $level != NORMAL ]] || reason=recovery
}
mailx_supports_subject() {
    local usage
    usage=$(mailx --help </dev/null 2>&1) || :
    [[ $usage =~ (^|[[:space:][:punct:]])-s([[:space:]=,]|$) ]]
}
deliver() {
    local metric=$1 old=$2 level=$3 value=$4 threshold=$5
    local id="$metric-$stamp-$level" recipient=${cfg[EMAIL_TO]} host subject body status detail
    host=$(hostname)
    [[ $host =~ ^[A-Za-z0-9._-]+$ ]] || host=unknown
    subject="SysGuard $host $metric $old to $level"
    body="$stamp $host $metric $value% threshold $threshold% $old -> $level"
    local ledger=$out/delivery.csv
    [[ -f $ledger ]] || printf 'timestamp,event_id,recipient,status,detail\n' > "$ledger"
    if [[ $mode == disabled ]]; then status=disabled detail=disabled
    else
        printf '%s,%s,%s,started,%s\n' "$stamp" "$id" "$recipient" "$mode" >> "$ledger"
        if [[ $mode == mock ]]; then
            if printf 'To: %s\nSubject: %s\n%s\n\n' "$recipient" "$subject" "$body" >> "$out/mock-mail.log"; then
                status=captured detail=mock
            else status=failed detail=mock_capture_error; result=5
            fi
        elif ! command -v mailx >/dev/null; then status=failed detail=mailx_missing; result=7
        elif ! mailx_supports_subject; then status=failed detail=unsupported_mailx; result=7
        elif printf '%s\n' "$body" | mailx -s "$subject" "$recipient" >/dev/null 2>&1; then
            status=submitted detail=mailx_exit_zero
        else status=failed detail=mailx_error; result=5
        fi
    fi
    printf '%s,%s,%s,%s,%s\n' "$stamp" "$id" "$recipient" "$status" "$detail" >> "$ledger"
}
# Walk components before normalizing ".." so a link cannot hide in the prefix.
safe_directory() {
    local path=$1 dir='' part
    local -a parts
    [[ $path != *[[:cntrl:]]* ]] || die 4 "unsafe directory"
    IFS=/ read -r -a parts <<< "$path"
    for part in "${parts[@]}"; do
        case $part in
            ''|.) continue;;
            ..) dir=${dir%/*}; continue;;
        esac
        dir+=/$part
        [[ ! -L $dir && ( ! -e $dir || -d $dir ) ]] || die 4 "unsafe directory: $dir"
    done
    printf '%s\n' "${dir:-/}"
}
acquire_lock() {
    local path=$1 kind=$2 status
    [[ ! -L $path && ( ! -e $path || -f $path ) ]] || die 4 "unsafe lock: $path"
    # Bash allocates held_fd in the caller. Append opens preserve existing bytes.
    exec {held_fd}>>"$path" || die 4 "cannot open lock: $path"
    [[ ! -L $path && -f /proc/self/fd/$held_fd && $path -ef /proc/self/fd/$held_fd ]] ||
        die 4 "lock changed while opening: $path"
    [[ $(stat -Lc '%h' "/proc/self/fd/$held_fd") == 1 ]] || die 4 "aliased lock: $path"
    flock "$kind" -n -E 6 "$held_fd" && return 0
    status=$?
    (( status != 6 )) || die 6 "lock busy: $path"
    die 4 "flock failed: $path"
}
alerts_main() {
    local config='' data='' mode=mock once=0
    while (($#)); do
        case $1 in
            --help) echo 'alerts.sh --once [--config FILE] [--data-dir DIR] [--mail-mode mock|real|disabled]'; return;;
            --once) once=1;;
            --config|--data-dir|--mail-mode)
                [[ -n ${2-} && $2 != --* ]] || die 2 "missing option value"
                case $1 in --config) config=$2;; --data-dir) data=$2;; --mail-mode) mode=$2;; esac
                shift;;
            *) die 2 "unexpected argument";;
        esac
        shift
    done
    [[ $once == 1 && $mode =~ ^(mock|real|disabled)$ ]] || die 2 "invalid action or mail mode"
    alerts_once "$config" "$data" "$mode"
}

# With an optional collector command, validate once and keep these settings for delivery.
alerts_once() (
    set -Eeuo pipefail
    trap 'die 4 "filesystem or command failure at line $LINENO"' ERR
    export LC_ALL=C
    umask 077
    local root config=$1 data=$2 mode=$3
    shift 3
    local -A cfg=()
    repo_root
    if (($#)); then
        # The monitor always requires tracked defaults, even with an explicit override.
        require_default_config
    fi
    load_config "$config"
    [[ $mode != real || ${cfg[MAIL_ENABLED]} == 1 ]] || die 2 "real mail disabled"
    if (($#)); then
        "$@" || exit "$?"
    fi
    command -v flock >/dev/null || die 7 "flock missing"
    data=$(safe_directory "$(absolute "${data:-data}")")
    local runtime out held_fd metrics_lock
    runtime=$(safe_directory "$root/runtime")
    out=$(safe_directory "$data/alerts")
    mkdir -p -- "$runtime"
    acquire_lock "$runtime/alerts.lock" -x
    # Leave the alert descriptor open through recovery, publication and delivery.
    mkdir -p -- "$data"
    metrics_lock=$data/.metrics.lock
    if [[ $data == "$root/data" || $data -ef $root/data ]]; then
        metrics_lock=$runtime/metrics.lock
    fi
    acquire_lock "$metrics_lock" -s
    mkdir -p -- "$out"
    tmp=$(mktemp -d "$out/.alerts.XXXXXXXX")
    trap 'rm -rf -- "$tmp"' EXIT
    if [[ -d $out/pending ]]; then publish; fi
    local stamp epoch level threshold reason i metric old result=0
    local -a metrics=(cpu memory disk) previous=() saved=() values=() numbers=() changed=() levels=() thresholds=()
    read_sample
    exec {held_fd}>&-
    read_state
    mkdir "$tmp/transaction"
    local stage=$tmp/transaction
    for i in 0 1 2; do
        metric=${metrics[i]} old=${previous[i]:-NORMAL}
        classify "$metric" "$old" "${numbers[i]}"
        printf '%s\t%s\t%s\t%s\n' "$metric" "$stamp" "$level" "${values[i]}" >> "$stage/state.tsv"
        if [[ $old != "$level" ]]; then
            changed+=("$i")
            if [[ ! -e $stage/events.csv ]]; then
                if [[ -e $out/events.csv ]]; then cp -- "$out/events.csv" "$stage/events.csv"
                else printf 'timestamp,metric,previous_state,new_state,value,threshold,reason\n' > "$stage/events.csv"
                fi
            fi
            printf '%s,%s,%s,%s,%s,%s,%s\n' "$stamp" "$metric" "$old" "$level" "${values[i]}" "$threshold" "$reason" >> "$stage/events.csv"
        fi
        levels+=("$level"); thresholds+=("$threshold")
    done
    mv -T -- "$stage" "$out/pending"
    publish
    for i in "${changed[@]}"; do
        deliver "${metrics[i]}" "${previous[i]:-NORMAL}" "${levels[i]}" "${values[i]}" "${thresholds[i]}"
    done
    (( result == 0 )) || die "$result" "delivery failed; see delivery.csv"
)
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then alerts_main "$@"; fi
