#!/usr/bin/env bash

readonly CSV_HEADER='timestamp,cpu_percent,memory_percent,disk_percent'

diagnostic() {
    printf 'report: %s\n' "$*" >&2
}

usage() {
    printf '%s\n' 'Usage: report.sh daily [--date YYYY-MM-DD] [--config FILE] [--data-dir DIR] [--output-dir DIR]' \
        '       report.sh --help' \
        'Without --date, reports the previous completed local day (using TZ or the system timezone).' \
        'Daily HTML requires REPORT_PDF_ENABLED=0. Relative paths resolve from the repository root.'
}

parse_args() {
    [[ ${1-} == daily ]] || return 2
    shift
    while (( $# )); do
        case $1 in
            --date|--config|--data-dir|--output-dir)
                [[ ${2-} && $2 != --* && ! ${options[$1]+set} ]] || return 2
                options[$1]=$2
                shift 2
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

local_day_start() {
    local day=$1 utc_start candidate previous_day lower upper middle observed_day
    if candidate=$(date -d "$day 00:00:00" +%s 2>/dev/null) &&
        previous_day=$(date -d "@$((candidate - 1))" +%F) && [[ $previous_day != "$day" ]]; then
        printf '%s\n' "$candidate"
        return
    fi

    # Some zones skip or repeat midnight. Find the first instant at or after
    # the requested calendar date, searching around its UTC midnight.
    utc_start=$(date -u -d "$day 00:00:00" +%s) || return 3
    lower=$((utc_start - 129600))
    upper=$((utc_start + 129600))
    while (( upper - lower > 1 )); do
        middle=$((lower + (upper - lower) / 2))
        observed_day=$(date -d "@$middle" +%F) || return 3
        if [[ $observed_day < $day ]]; then
            lower=$middle
        else
            upper=$middle
        fi
    done
    printf '%s\n' "$upper"
}

resolve_window() {
    local today next_day canonical_day
    if [[ ${options[--date]+set} ]]; then
        report_date=${options[--date]}
    else
        today=$(date +%F) || return 3
        report_date=$(date -u -d "$today 1 day ago" +%F) || return 3
    fi
    [[ $report_date =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ && $report_date != 0000-* ]] || return 3
    canonical_day=$(date -u -d "$report_date" +%F 2>/dev/null) || return 3
    [[ $canonical_day == "$report_date" ]] || return 3
    next_day=$(date -u -d "$report_date 1 day" +%F) || return 3
    start=$(local_day_start "$report_date") && end=$(local_day_start "$next_day") || return 3
}

take_lock() {
    local status
    flock -n -E 6 "$1" "$2" && return 0
    status=$?
    (( status == 6 )) && return 6
    return 4
}

lock_path_is_safe() {
    [[ ! -L $1 && ( ! -e $1 || -f $1 ) ]]
}

snapshot_metrics() (
    local data_dir=$1 snapshot=$2 parent lock_path lock_fd csv
    if [[ ! -d $data_dir ]]; then
        # An absent input directory is no data. An inaccessible parent or a
        # non-directory component is a path error.
        parent=$data_dir
        while [[ ! -e $parent && ! -L $parent ]]; do
            parent=${parent%/*}
            [[ $parent ]] || parent=/
        done
        [[ -d $parent && -x $parent ]] || return 4
        return 0
    fi
    data_dir=$(cd -P -- "$data_dir" && pwd -P) || return 4
    if [[ $data_dir == "$repo_root/data" || $data_dir -ef $repo_root/data ]]; then
        lock_path=$repo_root/runtime/metrics.lock
    else
        lock_path=$data_dir/.metrics.lock
    fi
    lock_path_is_safe "$lock_path" || return 4
    exec {lock_fd}>> "$lock_path" || return 4
    take_lock -s "$lock_fd" || return "$?"

    csv=$data_dir/metrics.csv
    if [[ -e $csv || -L $csv ]]; then
        [[ -f $csv && ! -L $csv ]] || return 4
        cat -- "$csv" > "$snapshot" || return 4
    fi
)

timestamp_epoch() {
    local timestamp=$1
    local format='^[0-9]{4}-[0-9]{2}-[0-9]{2}T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9][+-]([01][0-9]|2[0-3]):[0-5][0-9]$'
    [[ $timestamp =~ $format && $timestamp != 0000-* ]] || return 3
    date -d "$timestamp" +%s 2>/dev/null || return 3
}

select_samples() {
    local header line timestamp cpu memory disk epoch previous='' skipped=0 status
    local percent='^(([0-9]|[1-9][0-9])\.[0-9]|100\.0)$'
    local row_pattern='^([^,]+),([^,]+),([^,]+),([^,]+)$'

    [[ -s $1 ]] || return 0
    # Bash read skips NUL bytes. Reject them before reading the snapshot.
    awk 'index($0, sprintf("%c", 0)) { exit 3 }' "$1" || {
        status=$?
        if (( status == 3 )); then
            diagnostic 'invalid CSV: NUL byte'
            return 3
        fi
        return 4
    }
    {
        if ! IFS= read -r header || [[ $header != "$CSV_HEADER" ]]; then
            diagnostic 'invalid CSV header'
            return 3
        fi
        while IFS= read -r line; do
            if [[ $line =~ $row_pattern ]]; then
                timestamp=${BASH_REMATCH[1]}
                cpu=${BASH_REMATCH[2]}
                memory=${BASH_REMATCH[3]}
                disk=${BASH_REMATCH[4]}
                if [[ $cpu =~ $percent && $memory =~ $percent && $disk =~ $percent ]] &&
                    epoch=$(timestamp_epoch "$timestamp") && [[ ! $previous || $epoch -gt $previous ]]; then
                    previous=$epoch
                    if (( epoch >= start && epoch < end )); then
                        printf '%s\t%s\t%s\t%s\n' "$epoch" "$cpu" "$memory" "$disk" || return 4
                    fi
                    continue
                fi
            fi
            skipped=$((skipped + 1))
        done
        if [[ $line ]]; then
            diagnostic 'invalid CSV: missing final newline'
            return 3
        fi
    } < "$1"
    printf 'skipped\t%s\n' "$skipped" || return 4
}

summarize_samples() {
    awk -F '\t' -v cadence="${settings[WATCH_INTERVAL_SECONDS]}" '
        $1 == "skipped" { skipped = $2; next }
        {
            if (count == 0) first = $1
            else if ($1 - last > cadence) gaps++
            last = $1
            for (i = 2; i <= 4; i++) {
                # Store exact tenths for sums and round only for display.
                value = $i
                sub(/\./, "", value)
                value += 0
                if (count == 0 || value < min[i]) min[i] = value
                if (count == 0 || value > max[i]) max[i] = value
                sum[i] += value
            }
            count++
        }
        END {
            printf "%d\t%d\t%d\t%s\t%s\n", count, skipped, gaps, first, last
            label[2] = "CPU"; label[3] = "Memory"; label[4] = "Disk"
            for (i = 2; i <= 4; i++) {
                printf "      <tr><th scope=\"row\">%s</th><td>%d</td>", label[i], count
                if (count > 0)
                    printf "<td>%.1f%%</td><td>%.1f%%</td><td>%.2f%%</td>", min[i]/10, max[i]/10, sum[i]/count/10
                else
                    printf "<td>N/A</td><td>N/A</td><td>N/A</td>"
                print "</tr>"
            }
        }
    '
}

escape_html() {
    local value=$1
    value=${value//&/\&amp;}
    value=${value//</\&lt;}
    value=${value//>/\&gt;}
    value=${value//\"/\&quot;}
    value=${value//\'/\&#39;}
    printf '%s' "$value"
}

render_html() {
    local summary=$1 count skipped gaps first last heading quality coverage
    local from until zone from_html until_html zone_html first_html last_html
    IFS=$'\t' read -r count skipped gaps first last <<< "${summary%%$'\n'*}"
    if (( count == 0 && skipped > 0 )); then
        diagnostic "invalid CSV: skipped $skipped malformed rows and found no valid samples in the report window"
        return 3
    fi

    from=$(date -d "@$start" '+%F %T %:z') && until=$(date -d "@$end" '+%F %T %:z') || return 4
    zone=${TZ:-system local timezone}
    from_html=$(escape_html "$from")
    until_html=$(escape_html "$until")
    zone_html=$(escape_html "$zone")
    heading='Sampling summary'
    quality=''
    coverage='No valid samples in the active metrics log for this window.'
    if (( skipped > 0 )); then
        quality="<p><strong>Data quality warning.</strong> Skipped $skipped malformed or out-of-order rows in the active log.</p>"
        diagnostic "skipped $skipped malformed or out-of-order rows in the active log"
    fi
    if (( count > 0 )); then
        first=$(date -d "@$first" '+%F %T %:z') && last=$(date -d "@$last" '+%F %T %:z') || return 4
        first_html=$(escape_html "$first")
        last_html=$(escape_html "$last")
        coverage="Observed $first_html to $last_html. Intervals between valid samples longer than the configured watch interval (${settings[WATCH_INTERVAL_SECONDS]} seconds): $gaps."
    else
        heading='NO DATA'
    fi

    cat <<EOF
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>SysGuard Daily Report — $report_date</title>
  <style>
    body { font: 1rem/1.5 system-ui, sans-serif; margin: 2rem auto; max-width: 52rem; padding: 0 1rem; }
    table { border-collapse: collapse; width: 100%; }
    th, td { border-bottom: 1px solid #ccc; padding: .5rem; text-align: left; }
  </style>
</head>
<body>
  <main>
    <h1>SysGuard Daily Report — $report_date</h1>
    <p>Timezone: $zone_html</p>
    <p>Window: $from_html (inclusive) to $until_html (exclusive)</p>
    <h2>$heading</h2>
    <p>Valid samples: $count</p>
    <p>$coverage</p>
    $quality
    <table>
      <caption>Utilization from valid samples in the active metrics log</caption>
      <thead>
        <tr><th scope="col">Metric</th><th scope="col">Count</th><th scope="col">Minimum</th><th scope="col">Maximum</th><th scope="col">Arithmetic average</th></tr>
      </thead>
      <tbody>
${summary#*$'\n'}
      </tbody>
    </table>
  </main>
</body>
</html>
EOF
}

cleanup() {
    [[ $stage ]] || return 0
    rm -f -- "$stage/metrics.csv" "$stage/report.html" && rmdir -- "$stage"
}

main() {
    export LC_ALL=C
    umask 077
    if [[ $# == 1 && $1 == --help ]]; then
        usage
        return 0
    fi

    local -A options=() settings=()
    local script_dir repo_root config data_dir output_dir report_date start end
    local tool report_lock lock_fd summary status
    if ! parse_args "$@"; then
        diagnostic 'invalid arguments'
        usage >&2
        return 2
    fi
    for tool in awk cat date flock mkdir mktemp mv rm rmdir; do
        if ! command -v "$tool" >/dev/null; then
            diagnostic "required command unavailable: $tool"
            return 7
        fi
    done
    script_dir=${BASH_SOURCE[0]%/*}
    [[ $script_dir != "${BASH_SOURCE[0]}" ]] || script_dir=.
    repo_root=$(cd -P -- "$script_dir/.." && pwd -P) || return 4
    config=$(repo_path "${options[--config]:-config/local.conf}")
    data_dir=$(repo_path "${options[--data-dir]:-data}")
    output_dir=$(repo_path "${options[--output-dir]:-reports}")/daily
    load_config "$config" || {
        status=$?
        diagnostic 'configuration could not be loaded or validated'
        return "$status"
    }
    if ! resolve_window; then
        diagnostic 'invalid report date (expected a calendar date in YYYY-MM-DD)'
        return 3
    fi
    if (( settings[REPORT_PDF_ENABLED] )); then
        diagnostic 'PDF generation is unavailable in Phase 2. Use REPORT_PDF_ENABLED=0 for daily HTML.'
        return 7
    fi

    report_lock=$repo_root/runtime/report.lock
    if ! { mkdir -p -- "$repo_root/runtime" && lock_path_is_safe "$report_lock" && exec {lock_fd}>> "$report_lock"; }; then
        diagnostic 'could not open the report lock'
        return 4
    fi
    take_lock -x "$lock_fd" || {
        status=$?
        diagnostic 'could not acquire the report lock'
        return "$status"
    }
    if ! { mkdir -p -- "$output_dir" && stage=$(mktemp -d -- "$output_dir/.report.XXXXXXXX"); }; then
        diagnostic 'could not stage the HTML in the output directory'
        return 4
    fi
    snapshot_metrics "$data_dir" "$stage/metrics.csv" || {
        status=$?
        diagnostic 'could not snapshot the active metrics log or acquire its lock'
        return "$status"
    }
    summary=$(select_samples "$stage/metrics.csv" | summarize_samples) || {
        status=$?
        (( status == 3 )) && return 3
        diagnostic 'could not read or summarize the CSV snapshot'
        return 4
    }
    render_html "$summary" > "$stage/report.html" || {
        status=$?
        (( status == 3 )) && return 3
        diagnostic 'could not write the HTML report'
        return 4
    }
    mv -fT -- "$stage/report.html" "$output_dir/$report_date.html" || {
        diagnostic 'could not publish the HTML report'
        return 4
    }
    printf 'Wrote %s\n' "$output_dir/$report_date.html"
}

set -o pipefail
stage=''
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
main "$@"
