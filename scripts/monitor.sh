#!/usr/bin/env bash

readonly CSV_HEADER='timestamp,cpu_percent,memory_percent,disk_percent'

diagnostic() {
    printf 'monitor: %s\n' "$*" >&2
}

usage() {
    printf '%s\n' 'Usage: monitor.sh --once|--watch [--config FILE] [--data-dir DIR]' \
        '       monitor.sh --help' \
        'Watch starts immediately. The interval includes sampling time and missed starts are skipped.'
}

parse_args() {
    local config_seen=0 data_seen=0
    while (( $# )); do
        case $1 in
            --once|--watch)
                [[ -z $mode ]] || return 2
                mode=$1
                shift
                ;;
            --config|--data-dir)
                [[ ${2-} && $2 != --* ]] || return 2
                if [[ $1 == --config ]]; then
                    (( config_seen == 0 )) || return 2
                    config_seen=1
                    config_explicit=1
                    config_path=$2
                else
                    (( data_seen == 0 )) || return 2
                    data_seen=1
                    data_dir=$2
                fi
                shift 2
                ;;
            *) return 2 ;;
        esac
    done
    [[ -n $mode ]] || return 2
    [[ $config_path == /* ]] || config_path=$repo_root/$config_path
    [[ $data_dir == /* ]] || data_dir=$repo_root/$data_dir
}

read_config() {
    local path=$1 line key value contents descriptor
    local -A seen=()
    [[ -f $path ]] || return 2
    exec {descriptor}< "$path" || return 4
    if IFS= read -r -d '' contents <&"$descriptor"; then
        exec {descriptor}<&-
        return 2
    fi
    exec {descriptor}<&-
    while IFS= read -r line; do
        [[ -z $line || $line == \#* ]] && continue
        [[ $line =~ ^([A-Z_]+)=(.*)$ ]] || return 2
        key=${BASH_REMATCH[1]}
        value=${BASH_REMATCH[2]}
        [[ ${settings[$key]+known} && ! ${seen[$key]+duplicate} ]] || return 2
        [[ $value != *[[:cntrl:]]* && $value != *['$`;&|<>()']* ]] || return 2
        seen[$key]=1
        settings[$key]=$value
    done <<< "$contents"
}

load_validate_config() {
    local key metric warning critical value
    settings=(
        [CPU_WARNING]='' [CPU_CRITICAL]='' [MEMORY_WARNING]='' [MEMORY_CRITICAL]=''
        [DISK_WARNING]='' [DISK_CRITICAL]='' [DISK_MOUNT]='' [CPU_SAMPLE_SECONDS]=''
        [WATCH_INTERVAL_SECONDS]='' [MAX_DATA_AGE_SECONDS]='' [ALERT_HYSTERESIS_PERCENT]=''
        [LOG_RETENTION_DAYS]='' [EMAIL_TO]='' [MAIL_ENABLED]='' [REPORT_PDF_ENABLED]=''
    )
    read_config "$repo_root/config/defaults.conf" || return "$?"
    if [[ $config_explicit == 1 || -e $config_path || -L $config_path ]]; then
        read_config "$config_path" || return "$?"
        diagnostic "loaded configuration from $config_path"
    else
        diagnostic "loaded configuration from $repo_root/config/defaults.conf"
    fi

    for key in CPU_WARNING CPU_CRITICAL MEMORY_WARNING MEMORY_CRITICAL DISK_WARNING DISK_CRITICAL \
        CPU_SAMPLE_SECONDS WATCH_INTERVAL_SECONDS MAX_DATA_AGE_SECONDS ALERT_HYSTERESIS_PERCENT \
        LOG_RETENTION_DAYS MAIL_ENABLED REPORT_PDF_ENABLED; do
        value=${settings[$key]}
        # Bound arithmetic to decimal integers that fit safely in Bash.
        [[ $value =~ ^[0-9]{1,18}$ ]] || return 2
        settings[$key]=$((10#$value))
    done

    for metric in CPU MEMORY DISK; do
        warning=${settings[${metric}_WARNING]}
        critical=${settings[${metric}_CRITICAL]}
        (( warning < critical && critical <= 100 &&
            settings[ALERT_HYSTERESIS_PERCENT] <= warning )) || return 2
    done
    (( settings[ALERT_HYSTERESIS_PERCENT] <= 20 &&
        settings[CPU_SAMPLE_SECONDS] > 0 &&
        settings[WATCH_INTERVAL_SECONDS] > settings[CPU_SAMPLE_SECONDS] &&
        settings[MAX_DATA_AGE_SECONDS] >= settings[WATCH_INTERVAL_SECONDS] + settings[CPU_SAMPLE_SECONDS] &&
        settings[LOG_RETENTION_DAYS] > 0 &&
        settings[MAIL_ENABLED] <= 1 && settings[REPORT_PDF_ENABLED] <= 1 )) || return 2
    value=${settings[EMAIL_TO]}
    if [[ -n $value ]]; then
        [[ $value =~ ^[a-zA-Z0-9._%+][a-zA-Z0-9._%+-]*@[a-zA-Z0-9-]+(\.[a-zA-Z0-9-]+)+$ ]] || return 2
    else
        (( settings[MAIL_ENABLED] == 0 )) || return 2
    fi

    value=${settings[DISK_MOUNT]}
    [[ -n $value ]] || return 2
    [[ $value == /* ]] || value=$repo_root/$value
    [[ -d $value ]] || return 2
    mount=$(canonical_directory "$value") || return "$?"
}

canonical_directory() {
    ( CDPATH='' cd -P -- "$1" && pwd -P ) || return 4
}

read_cpu_counters() {
    local snapshot
    snapshot=$(cat /proc/stat) || return 4
    parse_cpu_counters <<< "$snapshot"
}

parse_cpu_counters() {
    awk '$1 == "cpu" {
        if (++count != 1 || NF < 9) exit 3
        for (i = 2; i <= 9; i++) {
            if ($i !~ /^[0-9]+$/) exit 3
            printf "%s%s", $i, (i == 9 ? "\n" : " ")
        }
    }
    END { if (count != 1) exit 3 }'
}

calculate_cpu_delta() {
    awk '
        NF != 8 { exit 3 }
        {
            for (i = 1; i <= 8; i++) {
                if ($i !~ /^[0-9]+$/) exit 3
                if (NR == 1) previous[i] = $i
                else {
                    delta = $i - previous[i]
                    if (delta < 0) exit 3
                    total += delta
                    if (i == 4 || i == 5) idle += delta
                }
            }
            if (NR == 2) {
                if (total <= 0 || idle > total) exit 3
                printf "%.1f\n", 100 * (1 - idle / total)
            }
        }
    ' <<< "$1"$'\n'"$2"
}

read_meminfo() {
    local snapshot
    snapshot=$(cat /proc/meminfo) || return 4
    parse_meminfo <<< "$snapshot"
}

parse_meminfo() {
    awk '
        $1 == "MemTotal:" || $1 == "MemAvailable:" {
            if (NF != 3 || $2 !~ /^[0-9]+$/ || $3 != "kB" || ++count[$1] != 1) {
                invalid = 1
                exit 3
            }
            value[$1] = $2 + 0
        }
        END {
            total = value["MemTotal:"]
            available = value["MemAvailable:"]
            if (invalid || count["MemTotal:"] != 1 || count["MemAvailable:"] != 1 ||
                total <= 0 || available > total) exit 3
            printf "%.1f\n", 100 * (total - available) / total
        }
    '
}

read_disk() {
    local output
    output=$(df -P -- "$1") || return 3
    parse_df "$1" <<< "$output"
}

parse_df() {
    # Parse the numeric columns preceding Use%; filesystem and mount names may contain spaces.
    DISK_TARGET=$1 awk '
        NR == 1 && ($1 != "Filesystem" || $5 != "Capacity" || $6 != "Mounted" || $7 != "on") {
            exit 3
        }
        NR == 2 {
            if (!match($0, /[[:blank:]]+[0-9]+[[:blank:]]+[0-9]+[[:blank:]]+-?[0-9]+[[:blank:]]+[0-9]+%[[:blank:]]+/))
                exit 3
            columns = substr($0, RSTART, RLENGTH)
            target = substr($0, RSTART + RLENGTH)
            sub(/^[[:blank:]]+/, "", columns)
            split(columns, fields, /[[:blank:]]+/)
            percent = fields[4]
            sub(/%$/, "", percent)
            if (target != ENVIRON["DISK_TARGET"] || percent + 0 > 100) exit 3
            valid = 1
        }
        END {
            if (!valid || NR != 2) exit 3
            printf "%.1f\n", percent + 0
        }
    '
}

sleep_sample() {
    if [[ $mode != --watch ]]; then
        sleep "$1"
        return
    fi
    (( stopping == 0 )) || return 0
    sleep "$1" &
    sleep_pid=$!
    if (( stopping )); then kill "$sleep_pid" 2>/dev/null || :; fi
    local result=0
    wait "$sleep_pid" || result=$?
    if (( stopping )); then
        wait "$sleep_pid" 2>/dev/null || :
        result=0
    fi
    sleep_pid=''
    return "$result"
}

sample_time() {
    date '+%Y-%m-%dT%H:%M:%S%:z'
}

acquire_lock() {
    local lock_path=$1 status
    exec {lock_fd}>>"$lock_path" || return 4
    flock -n -E 6 "$lock_fd" && return 0
    status=$?
    exec {lock_fd}>&-
    (( status == 6 )) && return 6
    return 4
}

timestamp_epoch() {
    local stamp=$1
    [[ $stamp =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-]([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || return 3
    date -d "$stamp" +%s 2>/dev/null || return 3
}

append_csv() {
    local active=$1 row=$2 epoch=$3 header line stamp previous='' timestamp last_byte
    local pct='([0-9]|[1-9][0-9])\.[0-9]|100\.0'
    local row_pattern="^([^,]+),($pct),($pct),($pct)$"
    temp_csv=$(mktemp -- "${active%/*}/.metrics.XXXXXXXX") || return 4
    if [[ -e $active || -L $active ]]; then
        [[ -f $active && ! -L $active ]] || return 4
        cat -- "$active" > "$temp_csv" || return 4
    fi
    if [[ -s $temp_csv ]]; then
        # Bash read skips NUL bytes, so reject them before parsing the CSV.
        awk 'index($0, sprintf("%c", 0)) { exit 3 }' "$temp_csv" || {
            [[ $? == 3 ]] && return 3
            return 4
        }
        {
            IFS= read -r header && [[ $header == "$CSV_HEADER" ]] || return 3
            while IFS= read -r line || [[ -n $line ]]; do
                [[ $line =~ $row_pattern ]] || return 3
                stamp=${BASH_REMATCH[1]}
                timestamp=$(timestamp_epoch "$stamp") || return 3
                [[ -z $previous || $timestamp -gt $previous ]] || return 3
                previous=$timestamp
            done
        } < "$temp_csv" || return 4
        # A missing final newline would concatenate the next sample.
        last_byte=$(tail -c 1 -- "$temp_csv" && printf x) || return 4
        [[ $last_byte == $'\nx' ]] || return 3
        [[ -z $previous || $epoch -gt $previous ]] || return 3
    else
        printf '%s\n' "$CSV_HEADER" > "$temp_csv" || return 4
    fi
    printf '%s\n' "$row" >> "$temp_csv" || return 4
    mv -fT -- "$temp_csv" "$active" || return 4
    temp_csv=''
}

cleanup_traps() {
    if [[ -n $temp_csv ]]; then
        rm -f -- "$temp_csv" || diagnostic 'could not remove staged CSV'
    fi
    # The process closes its lock descriptor on exit. Keep the lock inode.
}

collect_once() {
    local before after cpu memory disk timestamp epoch row lock_path
    before=$(read_cpu_counters) || return "$?"
    sleep_sample "${settings[CPU_SAMPLE_SECONDS]}" || return 3
    (( stopping == 0 )) || return 0
    after=$(read_cpu_counters) || return "$?"
    cpu=$(calculate_cpu_delta "$before" "$after") || return 3
    memory=$(read_meminfo) || return "$?"
    disk=$(read_disk "$mount") || return "$?"
    timestamp=$(sample_time) || return 3
    epoch=$(timestamp_epoch "$timestamp") || return 3
    row=$timestamp,$cpu,$memory,$disk

    mkdir -p -- "$data_dir" || return 4
    data_dir=$(canonical_directory "$data_dir") || return "$?"
    # Member C must use the same mapping: canonical default data uses the
    # repository runtime lock; every other canonical data directory owns its
    # persistent .metrics.lock. Open the active CSV only after acquiring it.
    if [[ $data_dir == "$repo_root/data" || $data_dir -ef $repo_root/data ]]; then
        mkdir -p -- "$repo_root/runtime" || return 4
        lock_path=$repo_root/runtime/metrics.lock
    else
        lock_path=$data_dir/.metrics.lock
    fi
    acquire_lock "$lock_path" || return "$?"
    append_csv "$data_dir/metrics.csv" "$row" "$epoch" || return "$?"
    exec {lock_fd}>&-
    printf '%s\n' "$row"
}

watch_stop() {
    stopping=1
    if [[ -n $sleep_pid ]]; then kill "$sleep_pid" 2>/dev/null || :; fi
}

uptime_ticks() {
    local uptime unused
    read -r uptime unused < /proc/uptime || return 4
    ticks=$((10#${uptime%.*} * 100 + 10#${uptime#*.}))
}

watch_loop() {
    local ticks origin elapsed seconds fraction delay
    local interval=${settings[WATCH_INTERVAL_SECONDS]}
    uptime_ticks || return 4
    origin=$ticks
    while (( stopping == 0 )); do
        collect_once || return "$?"
        (( stopping == 0 )) || break
        uptime_ticks || return 4
        elapsed=$((ticks - origin))
        seconds=$((interval - elapsed / 100 % interval))
        fraction=$((elapsed % 100))
        if (( fraction )); then
            seconds=$((seconds - 1))
            fraction=$((100 - fraction))
        fi
        printf -v delay '%d.%02d' "$seconds" "$fraction"
        sleep_sample "$delay" || return 3
    done
    return 0
}

monitor_main() {
    export LC_ALL=C
    umask 077
    local repo_root config_path data_dir mount tool status lock_fd temp_csv='' config_explicit=0
    local mode='' stopping=0 sleep_pid=''
    local -A settings
    if [[ $# == 1 && $1 == --help ]]; then
        usage
        return 0
    fi
    local script_dir=${BASH_SOURCE[0]%/*}
    [[ $script_dir != "${BASH_SOURCE[0]}" ]] || script_dir=.
    repo_root=$(canonical_directory "$script_dir/..") || return 4
    config_path=$repo_root/config/local.conf
    data_dir=$repo_root/data
    if ! parse_args "$@"; then
        diagnostic 'invalid arguments'
        usage >&2
        return 2
    fi
    for tool in awk cat date df flock mkdir mktemp mv rm sleep tail; do
        if ! command -v "$tool" >/dev/null; then
            diagnostic "required command unavailable: $tool"
            return 7
        fi
    done
    # Validate in the current shell so the merged settings remain available.
    load_validate_config || {
        status=$?
        diagnostic "configuration failed (exit $status)"
        return "$status"
    }
    trap cleanup_traps EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    status=0
    if [[ $mode == --watch ]]; then
        trap watch_stop INT TERM
        watch_loop || status=$?
    else
        collect_once || status=$?
    fi
    if (( status )); then
        case $status in
            3) diagnostic 'invalid measurement, CSV, or timestamp' ;;
            4) diagnostic 'filesystem or lock operation failed' ;;
            6) diagnostic 'metrics lock is busy' ;;
        esac
    fi
    cleanup_traps
    trap - EXIT INT TERM
    return "$status"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    monitor_main "$@"
fi
