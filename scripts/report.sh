#!/usr/bin/env bash

readonly CSV_HEADER='timestamp,cpu_percent,memory_percent,disk_percent'

diagnostic() {
    printf 'report: %s\n' "$*" >&2
}

usage() {
    printf '%s\n' 'Usage: report.sh daily|weekly [--date YYYY-MM-DD] [--config FILE] [--data-dir DIR] [--output-dir DIR]' \
        '       report.sh today [--config FILE] [--data-dir DIR] [--output-dir DIR]' \
        '       report.sh --help' \
        'Daily defaults to the previous completed local day.' \
        'Weekly defaults to the previous completed Monday–Sunday. An explicit date must be a Monday.' \
        'Today covers UTC midnight up to the captured current instant (exclusive).' \
        'Dates use TZ or the system timezone. Relative paths resolve from the repository root.' \
        'REPORT_PDF_ENABLED=1 adds a PDF report using WeasyPrint.'
}

parse_args() {
    case ${1-} in
        today|daily|weekly) period=$1 ;;
        *) return 2 ;;
    esac
    shift
    while (( $# )); do
        case $1 in
            --date|--config|--data-dir|--output-dir)
                [[ $period != today || $1 != --date ]] || return 2
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
    local today next_day canonical_day weekday days_back=1 days_in_period=1
    if [[ $period == today ]]; then
        export TZ=Etc/UTC
        end=$(date +%s) &&
            report_date=$(date -u -d "@$end" +%F) &&
            start=$(date -u -d "$report_date 00:00:00" +%s) || return 3
        report_name=$report_date
        report_label="$report_date (incomplete current-day report)"
        return 0
    fi
    if [[ ${options[--date]+set} ]]; then
        report_date=${options[--date]}
    else
        today=$(date +%F) || return 3
        if [[ $period == weekly ]]; then
            weekday=$(date -u -d "$today" +%u) || return 3
            days_back=$((weekday + 6))
        fi
        report_date=$(date -u -d "$today $days_back days ago" +%F) || return 3
    fi
    [[ $report_date =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ && $report_date != 0000-* ]] || return 3
    canonical_day=$(date -u -d "$report_date" +%F 2>/dev/null) || return 3
    [[ $canonical_day == "$report_date" ]] || return 3
    report_name=$report_date
    report_label=$report_date
    if [[ $period == weekly ]]; then
        weekday=$(date -u -d "$report_date" +%u) || return 3
        [[ $weekday == 1 ]] || return 3
        report_last=$(date -u -d "$report_date 6 days" +%F) || return 3
        report_name=${report_date}_to_${report_last}
        report_label="$report_date to $report_last"
        days_in_period=7
    fi
    next_day=$(date -u -d "$report_date $days_in_period days" +%F) || return 3
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

copy_snapshot() {
    if ! { cat -- "$1" > "$2" && cmp -s -- "$1" "$2"; }; then
        diagnostic "could not verify snapshot of ${1##*/}"
        return 4
    fi
}

snapshot_metrics() (
    local data_dir=$1 parent lock_path lock_fd csv
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
        copy_snapshot "$csv" "$stage/metrics.csv" || return 4
    fi
    snapshot_archives "$data_dir/archive"
)

snapshot_archives() {
    local archive_dir=$1 archive name first_day last_day
    [[ -e $archive_dir || -L $archive_dir ]] || return 0
    [[ -d $archive_dir && ! -L $archive_dir && -r $archive_dir && -x $archive_dir ]] || return 4

    # Filenames describe a complete calendar day in the rotation timezone.
    # Allow every numeric UTC offset in CSV v1 when selecting candidates.
    # The row timestamps decide exact membership after the snapshot.
    first_day=$(date -u -d "@$((start - 86400))" +%F) || return 4
    last_day=$(date -u -d "@$((end - 1 + 86400))" +%F) || return 4
    for archive in "$archive_dir"/metrics-*.csv.gz; do
        name=${archive##*/}
        [[ $name =~ ^metrics-([0-9]{4}-[0-9]{2}-[0-9]{2})\.csv\.gz$ ]] || continue
        [[ ${BASH_REMATCH[1]} < $first_day || ${BASH_REMATCH[1]} > $last_day ]] && continue
        [[ -f $archive && ! -L $archive ]] || return 4
        copy_snapshot "$archive" "$stage/$name" || return 4
    done
    return 0
}

timestamp_epoch() {
    local timestamp=$1
    local format='^[0-9]{4}-[0-9]{2}-[0-9]{2}T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9][+-]([01][0-9]|2[0-3]):[0-5][0-9]$'
    [[ $timestamp =~ $format && $timestamp != 0000-* ]] || return 3
    date -d "$timestamp" +%s 2>/dev/null || return 3
}

select_samples() {
    local header line timestamp cpu memory disk epoch previous='' skipped=0 records read_records=1 status
    local percent='^(([0-9]|[1-9][0-9])\.[0-9]|100\.0)$'
    local row_pattern='^([^,]+),([^,]+),([^,]+),([^,]+)$'

    [[ -s $1 ]] || return 0
    # Bash read skips NULs and can stop at an I/O error as well as EOF.
    # Count records independently before parsing to detect an incomplete read.
    records=$(awk 'index($0, sprintf("%c", 0)) { exit 3 } END { print NR }' "$1") || {
        status=$?
        if (( status == 3 )); then
            diagnostic 'invalid CSV: NUL byte'
            return 3
        fi
        return 4
    }
    {
        if ! IFS= read -r header; then
            if [[ -z $header ]]; then
                diagnostic 'incomplete CSV snapshot read'
                return 4
            fi
            diagnostic 'invalid CSV header: missing newline'
            return 3
        fi
        if [[ $header != "$CSV_HEADER" ]]; then
            diagnostic 'invalid CSV header'
            return 3
        fi
        while IFS= read -r line; do
            read_records=$((read_records + 1))
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
    } < "$1" || return 4
    if (( read_records != records )); then
        diagnostic 'incomplete CSV snapshot read'
        return 4
    fi
    printf 'skipped\t%s\n' "$skipped" || return 4
}

collect_samples() {
    local archive status
    select_samples "$stage/metrics.csv" || return "$?"
    for archive in "$stage"/metrics-*.csv.gz; do
        [[ -f $archive ]] || continue
        if ! gzip -t -- "$archive"; then
            diagnostic "corrupt gzip archive ${archive##*/}"
            return 3
        fi
        gzip -dc -- "$archive" > "$stage/archive.csv" || return 4
        if [[ ! -s $stage/archive.csv ]]; then
            diagnostic "invalid CSV header in archive ${archive##*/}"
            return 3
        fi
        select_samples "$stage/archive.csv" || {
            status=$?
            diagnostic "could not parse archive ${archive##*/}"
            return "$status"
        }
    done
    return 0
}

summarize_samples() {
    awk -F '\t' -v cadence="${settings[WATCH_INTERVAL_SECONDS]}" '
        $1 == "skipped" { skipped += $2; next }
        count > 0 && $1 == last {
            if ($2 == cpu && $3 == memory && $4 == disk) next
            printf "report: conflicting measurements at Unix timestamp %s\n", $1 > "/dev/stderr"
            conflict = 1
            exit 3
        }
        {
            if (count == 0) first = $1
            else if ($1 - last > cadence) {
                gaps++
                print "" > "samples.tsv"
            }
            print $0 > "samples.tsv"
            last = $1
            cpu = $2; memory = $3; disk = $4
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
            if (conflict) exit 3
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

chart_ticks() {
    local i tick label separator=''
    for i in 0 1 2 3 4; do
        tick=$((start + (end - start) * i / 4))
        label=$(date -d "@$tick" '+%m-%d %H:%M %:z') || return 4
        printf '%s"%s" %s' "$separator" "$label" "$tick" || return 4
        separator=', '
    done
}

render_chart() (
    local ticks
    ticks=$(chart_ticks) || return 4
    cd -- "$stage" || return 4
    # Only calendar labels and numeric values enter this fixed gnuplot script.
    gnuplot -d <<EOF
set terminal pngcairo size 1200,900 font "Sans,11"
set output "chart.png"
set multiplot layout 3,1 title "SysGuard ${period^} Report - $report_label"
set xrange [$start:$end]
set yrange [0:100]
set xtics ($ticks)
set grid
set key top left
set ylabel "CPU (%)"
plot "samples.tsv" using 1:2 with linespoints pt 7 lc rgb "#2563ab" title "CPU utilization"
set ylabel "Memory (%)"
plot "samples.tsv" using 1:3 with linespoints pt 7 lc rgb "#20764f" title "Memory utilization"
set ylabel "Disk (%)"
set xlabel "Local time (UTC offsets shown)"
plot "samples.tsv" using 1:4 with linespoints pt 7 lc rgb "#9e4422" title "Disk utilization"
unset multiplot
unset output
EOF
)

publish_chart() {
    local destination=$output_root/charts/$chart_name
    mkdir -p -- "$output_root/charts" || return 4
    # Keep old chart files addressable while their reports are being replaced.
    if [[ -e $destination || -L $destination ]]; then
        [[ -f $destination && ! -L $destination ]] && cmp -s -- "$stage/chart.png" "$destination" || return 4
        return 0
    fi
    chart_stage=$(mktemp -- "$output_root/charts/.chart.XXXXXXXX") || return 4
    cat -- "$stage/chart.png" > "$chart_stage" || return 4
    mv -fT -- "$chart_stage" "$destination" || return 4
    chart_stage=''
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
    local summary=$1 count skipped gaps first_epoch last_epoch heading quality coverage boundary_coverage chart=''
    local from until zone from_html until_html zone_html first last first_html last_html
    IFS=$'\t' read -r count skipped gaps first_epoch last_epoch <<< "${summary%%$'\n'*}"
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
    coverage='No valid samples in the available metrics logs for this window.'
    boundary_coverage="Unobserved window: $((end - start)) seconds."
    if (( skipped > 0 )); then
        quality="<p><strong>Data quality warning.</strong> Skipped $skipped malformed or out-of-order rows in the input logs.</p>"
        diagnostic "skipped $skipped malformed or out-of-order rows in the input logs"
    fi
    if (( count > 0 )); then
        first=$(date -d "@$first_epoch" '+%F %T %:z') && last=$(date -d "@$last_epoch" '+%F %T %:z') || return 4
        first_html=$(escape_html "$first")
        last_html=$(escape_html "$last")
        coverage="Observed $first_html to $last_html. Intervals between valid samples longer than the configured watch interval (${settings[WATCH_INTERVAL_SECONDS]} seconds): $gaps."
        boundary_coverage="Leading gap: $((first_epoch - start)) s. Trailing gap: $((end - last_epoch)) s to the exclusive end. These intervals describe sample timing."
        chart="<figure><img src=\"../charts/$chart_name\" width=\"1200\" height=\"900\" alt=\"Three charts showing CPU, memory, and disk utilization over time\"><figcaption>CPU, memory, and disk utilization over time. Offsets are shown on the time axis.</figcaption></figure>"
    else
        heading='NO DATA'
    fi

    cat <<EOF
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>SysGuard ${period^} Report — $report_label</title>
  <style>
    body { font: 1rem/1.5 system-ui, sans-serif; margin: 2rem auto; max-width: 52rem; padding: 0 1rem; }
    table { border-collapse: collapse; width: 100%; }
    th, td { border-bottom: 1px solid #ccc; padding: .5rem; text-align: left; }
    figure { margin: 1rem 0; }
    img { max-width: 100%; height: auto; }
    @media print {
      body { margin: 0; max-width: none; }
      figure { break-inside: avoid; }
    }
  </style>
</head>
<body>
  <main>
    <h1>SysGuard ${period^} Report — $report_label</h1>
    <p>Timezone: $zone_html</p>
    <p>Window: $from_html (inclusive) to $until_html (exclusive)</p>
    <h2>$heading</h2>
    <p>Valid samples: $count</p>
    <p>$coverage</p>
    <p>$boundary_coverage</p>
    $quality
    <table>
      <caption>Utilization from valid samples in the available metrics logs</caption>
      <thead>
        <tr><th scope="col">Metric</th><th scope="col">Count</th><th scope="col">Minimum</th><th scope="col">Maximum</th><th scope="col">Arithmetic average</th></tr>
      </thead>
      <tbody>
${summary#*$'\n'}
      </tbody>
    </table>
    $chart
  </main>
</body>
</html>
EOF
}

check_pdf_converter() {
    local help
    if ! help=$(weasyprint --allowed-protocols file --base-url . --help 2>&1) ||
        ! grep -Eq '(^|[[:blank:],])--allowed-protocols([[:blank:],=]|$)' <<< "$help" ||
        ! grep -Eq '(^|[[:blank:],])--base-url([[:blank:],=]|$)' <<< "$help"; then
        diagnostic 'unsupported WeasyPrint: requires --allowed-protocols and --base-url'
        return 7
    fi
}

render_pdf() {
    local pdf=$stage/report.pdf info
    if ! grep -Fxq -- '</html>' "$stage/report.html"; then
        diagnostic 'staged HTML is incomplete'
        return 4
    fi
    if [[ $chart_name ]]; then
        if [[ $(file -b --mime-type -- "$stage/chart.png") != image/png ]] ||
            ! grep -Fq -- "src=\"../charts/$chart_name\"" "$stage/report.html"; then
            diagnostic 'staged chart is invalid or missing from the HTML'
            return 4
        fi
        # Give the staged HTML the same relative chart layout it will have
        # after publication. Conversion reads only private, local files.
        if ! { mkdir -- "$stage/charts" && ln -T -- "$stage/chart.png" "$stage/charts/$chart_name"; }; then
            diagnostic 'could not stage the chart for PDF conversion'
            return 4
        fi
    fi
    if ! weasyprint --allowed-protocols file --base-url "$stage/$period/" "$stage/report.html" "$pdf"; then
        diagnostic 'WeasyPrint could not convert the HTML report'
        return 4
    fi
    if [[ ! -f $pdf || -L $pdf || $(file -b --mime-type -- "$pdf") != application/pdf ]] ||
        ! tail -c 8 -- "$pdf" | grep -aFxq -- '%%EOF' ||
        ! info=$(pdfinfo "$pdf") || ! grep -Eq '^Pages:[[:space:]]+[1-9][0-9]*[[:space:]]*$' <<< "$info"; then
        diagnostic 'WeasyPrint produced an invalid or incomplete PDF'
        return 4
    fi
    # WeasyPrint may succeed even when it could not load an image. Check that
    # the gnuplot figure is an actual image in the document.
    if [[ $chart_name ]] && ! pdfimages -list "$pdf" | awk '
        $3 == "image" && $4 == 1200 && $5 == 900 { chart = 1 }
        END { exit !chart }
    '; then
        diagnostic 'PDF is missing the embedded gnuplot chart'
        return 4
    fi
}

publish_reports() {
    local html=$output_dir/$report_name.html pdf=$output_dir/$report_name.pdf
    if (( settings[REPORT_PDF_ENABLED] )); then
        if [[ -e $pdf || -L $pdf ]]; then
            if ! { [[ -f $pdf || -L $pdf ]] && ln -PT -- "$pdf" "$stage/previous.pdf"; }; then
                diagnostic 'could not preserve the previous PDF before publication'
                return 4
            fi
        fi
        pending_pdf=$pdf
        if ! mv -fT -- "$stage/report.pdf" "$pdf"; then
            diagnostic 'could not publish the PDF report'
            return 4
        fi
    fi
    if ! mv -fT -- "$stage/report.html" "$html"; then
        diagnostic 'could not publish the HTML report'
        return 4
    fi
    pending_pdf=''
    printf 'Wrote %s\n' "$html"
    if (( settings[REPORT_PDF_ENABLED] )); then
        printf 'Wrote %s\n' "$pdf"
    fi
}

rollback_pdf() {
    # A successful same-filesystem rename removes its staged source. Roll
    # back only if the PDF moved and the HTML did not, including on trapped
    # signals. Untrappable interruption between the renames can expose both
    # generations at once.
    [[ $pending_pdf && ! -e $stage/report.pdf && -e $stage/report.html ]] || return 0
    if [[ -e $stage/previous.pdf || -L $stage/previous.pdf ]]; then
        if ! mv -fT -- "$stage/previous.pdf" "$pending_pdf"; then
            diagnostic "could not restore the previous PDF; backup retained at $stage/previous.pdf"
            return 4
        fi
    elif ! rm -f -- "$pending_pdf"; then
        diagnostic 'could not remove the new PDF after HTML publication failed'
        return 4
    fi
}

cleanup() {
    local keep_backup=0
    if [[ $chart_stage ]]; then
        rm -f -- "$chart_stage"
    fi
    [[ $stage ]] || return 0
    rollback_pdf || keep_backup=1
    if [[ -d $stage/charts ]]; then
        rm -f -- "$stage"/charts/*.png && rmdir -- "$stage/charts"
    fi
    rm -f -- "$stage/metrics.csv" "$stage"/metrics-*.csv.gz "$stage/archive.csv" \
        "$stage/candidates.tsv" "$stage/samples.tsv" "$stage/chart.png" "$stage/report.html" "$stage/report.pdf"
    if (( ! keep_backup )); then
        rm -f -- "$stage/previous.pdf" && rmdir -- "$stage"
    fi
}

main() {
    export LC_ALL=C
    umask 077
    if [[ $# == 1 && $1 == --help ]]; then
        usage
        return 0
    fi

    local -A options=() settings=()
    local script_dir repo_root data_dir output_root output_dir start end
    local period report_date report_last report_name report_label chart_name=''
    local tool report_lock lock_fd summary status chart_digest
    if ! parse_args "$@"; then
        diagnostic 'invalid arguments'
        usage >&2
        return 2
    fi
    for tool in awk cat cmp date flock gzip mkdir mktemp mv rm rmdir sha256sum sort stat; do
        if ! command -v "$tool" >/dev/null; then
            diagnostic "required command unavailable: $tool"
            return 7
        fi
    done
    script_dir=${BASH_SOURCE[0]%/*}
    [[ $script_dir != "${BASH_SOURCE[0]}" ]] || script_dir=.
    repo_root=$(CDPATH='' cd -P -- "$script_dir/.." && pwd -P && printf '.') || return 4
    repo_root=${repo_root%$'\n.'}
    # shellcheck source=scripts/config.sh
    source "$script_dir/config.sh" || {
        diagnostic 'shared configuration loader unavailable'
        return 7
    }
    sysguard_config_load "$repo_root" "${options[--config]-}" settings || {
        status=$?
        diagnostic 'configuration could not be loaded or validated'
        return "$status"
    }
    data_dir=$(repo_path "${options[--data-dir]:-data}")
    output_root=$(repo_path "${options[--output-dir]:-reports}")
    output_dir=$output_root/$period
    if ! resolve_window; then
        if [[ $period == today ]]; then diagnostic 'could not determine the current UTC reporting window'
        else diagnostic 'invalid report date (expected a calendar date in YYYY-MM-DD, Monday for weekly)'; fi
        return 3
    fi
    if (( settings[REPORT_PDF_ENABLED] )); then
        for tool in weasyprint file grep ln pdfinfo pdfimages tail; do
            if ! command -v "$tool" >/dev/null; then
                diagnostic "required command unavailable: $tool"
                return 7
            fi
        done
        check_pdf_converter || return "$?"
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
    snapshot_metrics "$data_dir" || {
        status=$?
        diagnostic 'could not snapshot the metrics log or acquire its lock, or could not read an archive'
        return "$status"
    }
    collect_samples > "$stage/candidates.tsv" || {
        status=$?
        (( status == 3 )) && return 3
        diagnostic 'could not read the metrics snapshot'
        return 4
    }
    summary=$(cd -- "$stage" && sort -k1,1n candidates.tsv | summarize_samples) || {
        status=$?
        (( status == 3 )) && return 3
        diagnostic 'could not read or summarize the CSV snapshot'
        return 4
    }
    if [[ -s $stage/samples.tsv ]]; then
        if ! command -v gnuplot >/dev/null; then
            diagnostic 'required command unavailable: gnuplot'
            return 7
        fi
        if ! render_chart || [[ ! -s $stage/chart.png ]]; then
            diagnostic 'could not generate the gnuplot chart'
            return 4
        fi
        chart_digest=$(sha256sum < "$stage/chart.png") || {
            diagnostic 'could not read the staged chart'
            return 4
        }
        chart_name=$period-$report_name-${chart_digest%% *}.png
    fi
    render_html "$summary" > "$stage/report.html" || {
        status=$?
        (( status == 3 )) && return 3
        diagnostic 'could not write the HTML report'
        return 4
    }
    if (( settings[REPORT_PDF_ENABLED] )); then
        render_pdf || return "$?"
    fi
    if [[ $chart_name ]] && ! publish_chart; then
        diagnostic 'could not publish the chart'
        return 4
    fi
    publish_reports
}

set -o pipefail
stage=''
chart_stage=''
pending_pdf=''
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
main "$@"
