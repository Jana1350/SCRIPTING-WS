#!/usr/bin/env bash

readonly CSV_HEADER='timestamp,cpu_percent,memory_percent,disk_percent'

diagnostic() {
    printf 'rotation: %s\n' "$*" >&2
}

usage() {
    printf '%s\n' 'Usage: rotate_logs.sh [--as-of YYYY-MM-DD] [--config FILE] [--data-dir DIR] [--dry-run]' \
        '       rotate_logs.sh --help' \
        'Archives dates strictly before --as-of (default today in TZ or the system timezone).' \
        'Dry-run previews rotation and retention without writing anything.'
}

parse_args() {
    while (( $# )); do
        case $1 in
            --as-of|--config|--data-dir)
                [[ ${2-} && $2 != --* && ! ${options[$1]+set} ]] || return 2
                options[$1]=$2
                shift 2
                ;;
            --dry-run)
                (( ! dry_run )) || return 2
                dry_run=1
                shift
                ;;
            *) return 2 ;;
        esac
    done
}

repo_path() {
    if [[ $1 == /* ]]; then
        printf '%s\n' "$1"
    else
        printf '%s/%s\n' "$repo_root" "$1"
    fi
}

read_config() {
    local path=$1 fd contents line key value
    local -A seen=()
    [[ -f $path ]] || return 2
    exec {fd}< "$path" || return 4
    # Reading up to NUL lets us reject binary content before parsing it as text.
    if IFS= read -r -d '' contents <&"$fd"; then
        exec {fd}<&-
        return 2
    fi
    exec {fd}<&-
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

load_config() {
    local override=$1 key value metric warning critical
    settings=(
        [CPU_WARNING]='' [CPU_CRITICAL]='' [MEMORY_WARNING]='' [MEMORY_CRITICAL]=''
        [DISK_WARNING]='' [DISK_CRITICAL]='' [DISK_MOUNT]='' [CPU_SAMPLE_SECONDS]=''
        [WATCH_INTERVAL_SECONDS]='' [MAX_DATA_AGE_SECONDS]='' [ALERT_HYSTERESIS_PERCENT]=''
        [LOG_RETENTION_DAYS]='' [EMAIL_TO]='' [MAIL_ENABLED]='' [REPORT_PDF_ENABLED]=''
    )
    read_config "$repo_root/config/defaults.conf" || return "$?"
    if [[ ${options[--config]+set} || -e $override || -L $override ]]; then
        read_config "$override" || return "$?"
        diagnostic "loaded defaults and override $override"
    else
        diagnostic "loaded $repo_root/config/defaults.conf"
    fi

    for key in CPU_WARNING CPU_CRITICAL MEMORY_WARNING MEMORY_CRITICAL DISK_WARNING DISK_CRITICAL \
        CPU_SAMPLE_SECONDS WATCH_INTERVAL_SECONDS MAX_DATA_AGE_SECONDS ALERT_HYSTERESIS_PERCENT \
        LOG_RETENTION_DAYS MAIL_ENABLED REPORT_PDF_ENABLED; do
        value=${settings[$key]}
        [[ $value =~ ^[0-9]{1,18}$ ]] || return 2
        settings[$key]=$((10#$value))
    done
    for metric in CPU MEMORY DISK; do
        warning=${settings[${metric}_WARNING]}
        critical=${settings[${metric}_CRITICAL]}
        (( warning < critical && critical <= 100 && settings[ALERT_HYSTERESIS_PERCENT] <= warning )) || return 2
    done
    (( settings[ALERT_HYSTERESIS_PERCENT] <= 20 && settings[CPU_SAMPLE_SECONDS] > 0 &&
        settings[WATCH_INTERVAL_SECONDS] > settings[CPU_SAMPLE_SECONDS] &&
        settings[MAX_DATA_AGE_SECONDS] >= settings[WATCH_INTERVAL_SECONDS] + settings[CPU_SAMPLE_SECONDS] &&
        settings[LOG_RETENTION_DAYS] > 0 && settings[MAIL_ENABLED] <= 1 && settings[REPORT_PDF_ENABLED] <= 1 )) || return 2

    value=${settings[EMAIL_TO]}
    if [[ -n $value ]]; then
        [[ $value =~ ^[a-zA-Z0-9._%+][a-zA-Z0-9._%+-]*@[a-zA-Z0-9-]+(\.[a-zA-Z0-9-]+)+$ ]] || return 2
    else
        (( settings[MAIL_ENABLED] == 0 )) || return 2
    fi
    value=${settings[DISK_MOUNT]}
    [[ -n $value ]] || return 2
    value=$(repo_path "$value")
    [[ -d $value && -x $value ]] || return 2
}
calendar_date() {
    [[ $1 =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ && $1 != 0000-* ]] || return 3
    [[ $(date -u -d "$1" +%F 2>/dev/null) == "$1" ]]
}

safe_data_path() {
    local path=$1 component directory=''
    local -a components
    [[ $path != *[[:cntrl:]]* ]] || return 4
    [[ $path == /* ]] || path=$repo_root/$path
    IFS=/ read -r -a components <<< "${path#/}"
    # Walk from the root so a symlink is rejected before a later component
    # could traverse it. Normalize dot components for the writer's lock mapping.
    for component in "${components[@]}"; do
        case $component in
            ''|.) ;;
            ..) directory=${directory%/*} ;;
            *)
                directory+=/$component
                [[ ! -L $directory ]] || return 4
                if [[ -e $directory && ( ! -d $directory || ! -x $directory ) ]]; then
                    return 4
                fi
                ;;
        esac
    done
    [[ $directory ]] || return 4
    printf '%s\n' "$directory"
}

safe_archive_dir() {
    [[ ! -L $archive_dir && ( ! -e $archive_dir || ( -d $archive_dir && -r $archive_dir && -x $archive_dir ) ) ]]
}

acquire_metrics_lock() {
    local lock_path=$data_dir/.metrics.lock status
    # Match the writer's canonical default and override lock mapping.
    if [[ $data_dir == "$repo_root/data" || $data_dir -ef $repo_root/data ]]; then
        [[ ! -L $repo_root/runtime && ( ! -e $repo_root/runtime || -d $repo_root/runtime ) ]] || return 4
        if (( ! dry_run )); then
            mkdir -p -- "$repo_root/runtime" || return 4
        fi
        lock_path=$repo_root/runtime/metrics.lock
    fi
    [[ ! -L $lock_path && ( ! -e $lock_path || -f $lock_path ) ]] || return 4
    if (( dry_run )); then
        if [[ ! -e $lock_path ]]; then
            diagnostic 'metrics lock is absent; dry-run is an advisory preview and leaves it absent'
            return 0
        fi
        exec {lock_fd}< "$lock_path" || return 4
        flock -n -s -E 6 "$lock_fd" && return 0
    else
        exec {lock_fd}>> "$lock_path" || return 4
        flock -n -x -E 6 "$lock_fd" && return 0
    fi
    status=$?
    (( status == 6 )) && return 6
    return 4
}

parse_sample() {
    local row=$1 timestamp cpu memory disk stamp
    local fields='^([^,]+),([^,]+),([^,]+),([^,]+)$'
    local percent='^(([0-9]|[1-9][0-9])\.[0-9]|100\.0)$'
    local iso='^[0-9]{4}-[0-9]{2}-[0-9]{2}T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9][+-]([01][0-9]|2[0-3]):[0-5][0-9]$'

    [[ $row =~ $fields ]] || return 3
    timestamp=${BASH_REMATCH[1]}
    cpu=${BASH_REMATCH[2]}
    memory=${BASH_REMATCH[3]}
    disk=${BASH_REMATCH[4]}
    [[ $cpu =~ $percent && $memory =~ $percent && $disk =~ $percent ]] || return 3
    [[ $timestamp =~ $iso && $timestamp != 0000-* ]] || return 3
    # The explicit offset is used to parse the instant. %F is the date of
    # that instant in the rotation timezone, regardless of the row's offset.
    stamp=$(date -d "$timestamp" '+%s %F' 2>/dev/null) || return 3
    read -r epoch day <<< "$stamp"
    [[ $epoch =~ ^-?[0-9]+$ && $day =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 3
}

split_active_csv() {
    local input=$1 header row epoch day previous='' total row_number=1 status
    # Bash read drops NULs. Check for those bytes and count records in a
    # separate pass so a premature read cannot be mistaken for end of file.
    total=$(awk 'index($0, sprintf("%c", 0)) { exit 3 } END { print NR }' "$input") || {
        status=$?
        (( status == 3 )) && diagnostic 'invalid CSV: NUL byte'
        return "$((status == 3 ? 3 : 4))"
    }
    {
        if ! IFS= read -r header || [[ $header != "$CSV_HEADER" ]]; then
            diagnostic 'invalid CSV header'
            return 3
        fi
        while IFS= read -r row; do
            row_number=$((row_number + 1))
            if ! parse_sample "$row" || [[ $previous && $epoch -le $previous ]]; then
                diagnostic "invalid CSV row $row_number or timestamp order"
                return 3
            fi
            previous=$epoch
            if [[ $day < $as_of ]]; then
                if [[ ! ${counts[$day]+set} ]]; then
                    days+=("$day")
                    counts[$day]=0
                    if [[ $data_stage ]]; then
                        printf '%s\n' "$CSV_HEADER" > "$data_stage/$day.csv" || return 4
                    fi
                fi
                counts[$day]=$((counts[$day] + 1))
                if [[ $data_stage ]]; then
                    printf '%s\n' "$row" >> "$data_stage/$day.csv" || return 4
                fi
            elif [[ $data_stage ]]; then
                printf '%s\n' "$row" >> "$data_stage/active.csv" || return 4
            fi
        done
        if [[ $row ]]; then
            diagnostic 'invalid CSV: missing final newline'
            return 3
        fi
    } < "$input" || return 4
    (( row_number == total )) || return 4
}

verify_archive() {
    local compressed=$1 expected=$2 count=$3 actual status
    gzip -t -- "$compressed" || return 3
    gzip -dc -- "$compressed" > "$data_stage/check.csv" || return 4
    actual=$(wc -l < "$data_stage/check.csv") || return 4
    (( actual == count + 1 )) || return 3
    cmp -s -- "$expected" "$data_stage/check.csv" && return 0
    status=$?
    (( status == 1 )) && return 3
    return 4
}

prepare_archives() {
    local day name final staged status
    mkdir -p -- "$archive_dir" && safe_archive_dir || return 4
    archive_stage=$(mktemp -d -- "$archive_dir/.rotate.XXXXXXXX") || return 4
    for day in "${days[@]}"; do
        name=metrics-$day.csv.gz
        final=$archive_dir/$name
        if [[ -e $final || -L $final ]]; then
            if [[ ! -f $final || -L $final || ! -r $final ]]; then
                diagnostic "unsafe archive path or unreadable archive: $name"
                return 4
            fi
            verify_archive "$final" "$data_stage/$day.csv" "${counts[$day]}" || {
                status=$?
                diagnostic "existing archive is corrupt or does not match active rows: $name"
                return "$status"
            }
        else
            staged=$archive_stage/$name
            gzip -nc -- "$data_stage/$day.csv" > "$staged" || return 4
            verify_archive "$staged" "$data_stage/$day.csv" "${counts[$day]}" || {
                diagnostic "could not validate the staged archive $name"
                return 4
            }
        fi
    done
}

publish_rotation() {
    local day name staged final
    for day in "${days[@]}"; do
        name=metrics-$day.csv.gz
        staged=$archive_stage/$name
        final=$archive_dir/$name
        if [[ -e $staged ]]; then
            sync -- "$staged" || return 4
            # No clobber also protects an unexpected destination that appears
            # after validation. GNU mv -n may succeed without moving the file.
            mv -nT -- "$staged" "$final" && [[ ! -e $staged ]] || return 4
        fi
        [[ -f $final && ! -L $final ]] && sync -- "$final" || return 4
    done
    # Establish durable archives, including their directory entries, before
    # replacing the active CSV. A retry can verify any already-published days.
    sync -- "$archive_dir" "$data_dir" "$data_stage/active.csv" || return 4
    mv -fT -- "$data_stage/active.csv" "$active" || return 4
    if ! sync -- "$data_dir"; then
        diagnostic 'active CSV was replaced, but syncing its directory failed; verified archives are available'
        return 4
    fi
}

preview_retention() {
    local weekday protected_since as_of_epoch archive name archive_day archive_epoch age
    weekday=$(date -u -d "$as_of" +%u) || return 4
    protected_since=$(date -u -d "$as_of $((weekday + 6)) days ago" +%F) || return 4
    as_of_epoch=$(date -u -d "$as_of" +%s) || return 4

    printf 'Retention preview: %s completed days retained; dates from %s reserved for weekly reports.\n' \
        "${settings[LOG_RETENTION_DAYS]}" "$protected_since"
    for archive in "$archive_dir"/metrics-*.csv.gz; do
        [[ -f $archive && ! -L $archive ]] || continue
        name=${archive##*/}
        archive_day=${name#metrics-}
        archive_day=${archive_day%.csv.gz}
        calendar_date "$archive_day" && [[ $archive_day < $protected_since ]] || continue
        archive_epoch=$(date -u -d "$archive_day" +%s) || return 4
        age=$(((as_of_epoch - archive_epoch) / 86400))
        if (( age > settings[LOG_RETENTION_DAYS] )); then
            printf 'Retention candidate: %s (%d days old; confirm demo protection).\n' "$name" "$age"
        fi
    done
}

preview_rotation() {
    local day name final
    printf 'Dry-run: rotate completed dates before %s (%s).\n' "$as_of" "${TZ:-system local timezone}"
    if (( ${#days[@]} == 0 )); then
        printf '%s\n' 'No completed dates in the active log.'
    fi
    for day in "${days[@]}"; do
        name=metrics-$day.csv.gz
        final=$archive_dir/$name
        if [[ -e $final || -L $final ]]; then
            if [[ ! -f $final || -L $final ]]; then
                diagnostic "unsafe archive path $name"
                return 4
            fi
            if ! gzip -t -- "$final"; then
                diagnostic "corrupt existing archive: $name"
                return 3
            fi
            printf 'Compare %s with %d active rows before reuse.\n' "$name" "${counts[$day]}"
        else
            printf 'Create %s with %d rows.\n' "$name" "${counts[$day]}"
        fi
    done
    preview_retention
}

cleanup() {
    if [[ $archive_stage ]]; then
        rm -f -- "$archive_stage"/metrics-*.csv.gz && rmdir -- "$archive_stage"
    fi
    if [[ $data_stage ]]; then
        rm -f -- "$data_stage"/????-??-??.csv "$data_stage/active.csv" "$data_stage/check.csv" && rmdir -- "$data_stage"
    fi
}

main() {
    export LC_ALL=C
    umask 077
    if [[ $# == 1 && $1 == --help ]]; then
        usage
        return 0
    fi

    local -A options=() settings=() counts=()
    local -a days=()
    local tool script_dir repo_root config data_dir archive_dir active today as_of status lock_fd dry_run=0
    if ! parse_args "$@"; then
        diagnostic 'invalid arguments'
        usage >&2
        return 2
    fi
    for tool in awk cmp date flock gzip mkdir mktemp mv rm rmdir sync wc; do
        if ! command -v "$tool" >/dev/null; then
            diagnostic "required command unavailable: $tool"
            return 7
        fi
    done
    script_dir=${BASH_SOURCE[0]%/*}
    [[ $script_dir != "${BASH_SOURCE[0]}" ]] || script_dir=.
    repo_root=$(CDPATH='' cd -P -- "$script_dir/.." && pwd -P) || return 4
    config=$(repo_path "${options[--config]:-config/local.conf}")
    load_config "$config" || {
        status=$?
        diagnostic 'configuration could not be loaded or validated'
        return "$status"
    }
    today=$(date +%F) || return 3
    as_of=${options[--as-of]:-$today}
    if ! calendar_date "$as_of" || [[ $as_of > $today ]]; then
        diagnostic 'invalid --as-of date (use a calendar date no later than today)'
        return 3
    fi

    data_dir=$(safe_data_path "${options[--data-dir]:-data}") || {
        diagnostic 'unsafe or inaccessible data directory'
        return 4
    }
    archive_dir=$data_dir/archive
    if [[ -d $data_dir ]]; then
        acquire_metrics_lock || {
            status=$?
            diagnostic 'could not acquire the shared metrics lock'
            return "$status"
        }
    fi
    if ! safe_archive_dir; then
        diagnostic 'unsafe or inaccessible archive directory'
        return 4
    fi
    active=$data_dir/metrics.csv
    if [[ -e $active || -L $active ]]; then
        if [[ ! -f $active || -L $active || ! -r $active ]]; then
            diagnostic 'unsafe or unreadable active CSV'
            return 4
        fi
        if [[ -s $active ]]; then
            if (( ! dry_run )); then
                if ! { data_stage=$(mktemp -d -- "$data_dir/.rotate.XXXXXXXX") &&
                    printf '%s\n' "$CSV_HEADER" > "$data_stage/active.csv"; }; then
                    diagnostic 'could not stage the active CSV'
                    return 4
                fi
            fi
            split_active_csv "$active" || {
                status=$?
                (( status == 4 )) && diagnostic 'could not read or stage the active CSV'
                return "$status"
            }
        fi
    fi
    if (( dry_run )); then
        preview_rotation
        return "$?"
    fi
    if (( ${#days[@]} == 0 )); then
        printf '%s\n' 'No completed dates in the active log.'
        return 0
    fi

    prepare_archives || {
        status=$?
        diagnostic 'archive preparation failed; the active CSV was preserved'
        return "$status"
    }
    publish_rotation || {
        diagnostic 'rotation publication failed; any published archives can be checked on retry'
        return 4
    }
    printf 'Rotated %d completed dates before %s.\n' "${#days[@]}" "$as_of"
}

data_stage=''
archive_stage=''
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
main "$@"
