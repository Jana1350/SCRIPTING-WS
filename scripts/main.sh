#!/usr/bin/env bash

main_usage() {
    printf '%s\n' 'Usage: main.sh --help' \
        '       main.sh --status|--report daily|--report weekly [--config FILE] [--data-dir DIR]' \
        '       main.sh --once [--config FILE] [--data-dir DIR] [--mail-mode real]'
}

require_script() {
    [[ -f $1 && -x $1 ]] || {
        printf 'main: required executable unavailable: %s\n' "$1" >&2
        return 7
    }
}

run_once() (
    local scripts=$1 config_override=$2 metrics_dir=$3 delivery_mode=$4
    shift 4
    # shellcheck source=scripts/alerts.sh
    source "$scripts/alerts.sh" || exit 7
    alerts_once "$config_override" "$metrics_dir" "$delivery_mode" "$scripts/monitor.sh" --once "$@"
)

preflight_config() {
    local repo_root=$1 override=$2 mode=$3 status
    local -A settings=()
    # Keep the same shared preflight until the alert loader adopts it.
    # shellcheck source=scripts/config.sh
    source "$repo_root/scripts/config.sh" || return 7
    sysguard_config_load "$repo_root" "$override" settings || {
        status=$?
        printf 'main: configuration failed (exit %d)\n' "$status" >&2
        return "$status"
    }
    if [[ $mode == real && ${settings[MAIL_ENABLED]} != 1 ]]; then
        printf 'main: real mail disabled\n' >&2
        return 2
    fi
}

show_status() {
    local data_dir=$1
    local csv=$data_dir/metrics.csv
    if [[ -e $csv || -L $csv ]]; then
        if [[ ! -f $csv || ! -r $csv || -L $csv ]]; then
            printf 'main: metrics file is inaccessible: %s\n' "$csv" >&2
            return 4
        fi
        printf 'Metrics file present: %s\n' "$csv"
    else
        local parent=$data_dir
        while [[ ! -e $parent && ! -L $parent ]]; do
            parent=${parent%/*}
            [[ -n $parent ]] || parent=/
        done
        if [[ ! -d $parent || ! -x $parent ]]; then
            printf 'main: metrics directory inaccessible: %s\n' "$parent" >&2
            return 4
        fi
        printf 'No metrics file yet: %s\n' "$csv"
    fi
}

main() {
    export LC_ALL=C
    if [[ $# == 1 && $1 == --help ]]; then main_usage; return 0; fi
    local script_dir=${BASH_SOURCE[0]%/*} repo_root
    [[ $script_dir != "${BASH_SOURCE[0]}" ]] || script_dir=.
    repo_root=$(CDPATH='' cd -P -- "$script_dir/.." && pwd -P && printf '.') || return 4
    repo_root=${repo_root%$'\n.'}
    local mode='' period='' config='' data='' mail_mode='' path
    local -a options=()
    while (( $# )); do
        case $1 in
            --once|--status|--report)
                [[ -z $mode ]] || return 2
                mode=$1
                if [[ $mode == --report ]]; then
                    [[ ${2-} == daily || ${2-} == weekly ]] || return 2
                    period=$2
                    shift
                fi
                ;;
            --config|--data-dir)
                [[ ${2-} && $2 != --* ]] || return 2
                if [[ $1 == --config && $2 =~ [[:cntrl:]] ]]; then return 2; fi
                path=$2
                [[ $path == /* ]] || path=$repo_root/$path
                if [[ $1 == --config ]]; then
                    [[ -z $config ]] || return 2
                    config=$path
                else
                    [[ -z $data ]] || return 2
                    data=$path
                fi
                options+=("$1" "$path")
                shift
                ;;
            --mail-mode)
                [[ ${2-} == real && -z $mail_mode ]] || return 2
                mail_mode=real
                shift
                ;;
            *) return 2 ;;
        esac
        shift
    done
    [[ $mode == --once || -z $mail_mode ]] || return 2

    local scripts=$repo_root/scripts
    case $mode in
        --status)
            require_script "$scripts/monitor.sh" || return 7
            preflight_config "$repo_root" "$config" mock || return "$?"
            show_status "${data:-$repo_root/data}"
            ;;
        --once)
            require_script "$scripts/monitor.sh" && require_script "$scripts/alerts.sh" || return 7
            preflight_config "$repo_root" "$config" "${mail_mode:-mock}" || return "$?"
            run_once "$scripts" "$config" "$data" "${mail_mode:-mock}" "${options[@]}"
            ;;
        --report)
            require_script "$scripts/report.sh" || return 7
            "$scripts/report.sh" "$period" "${options[@]}"
            ;;
        *) return 2 ;;
    esac
}

main "$@"
status=$?
if (( status == 2 )); then main_usage >&2; fi
exit "$status"
