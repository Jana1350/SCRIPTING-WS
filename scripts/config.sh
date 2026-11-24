#!/usr/bin/env bash
# Source this module, then call:
#   sysguard_config_load REPO_ROOT OVERRIDE OUTPUT [allow-standalone]
# REPO_ROOT is an absolute checkout path. OVERRIDE is a config path (relative
# paths resolve from REPO_ROOT), or empty to use optional config/local.conf.
# OUTPUT names a plain writable Bash associative array (declare -A or -Ax).
# Names beginning with _sc_ and LC_ALL are reserved.
# Defaults are required unless allow-standalone is supplied with an explicit
# config containing all keys. An override pointing to defaults is read once.
# On success OUTPUT holds every whitelisted key below. Integer input is one
# to eighteen decimal digits (including any padding), normalized in OUTPUT.
# Booleans retain exactly 0 or 1, and DISK_MOUNT is a physical absolute path.
# Returns 0 on success, 2 for invalid input or a missing required file, and 4
# for an unreadable file, an I/O error or directory resolution failure.
# Failure leaves OUTPUT unchanged.
# Requires GNU stat and procfs for regular-file reads. Writes only diagnostics
# and file paths to stderr. It performs no collection,
# delivery, directory creation or writes to configuration or runtime files.

_sysguard_config_read() {
    local _sc_file=$1 _sc_fd _sc_size _sc_contents _sc_line _sc_key _sc_value
    local -n _sc_target=$2
    local -A _sc_seen=()
    [[ -f $_sc_file ]] || return 2
    if [[ ! -r $_sc_file ]]; then
        printf 'sysguard: unreadable configuration file: %s\n' "$_sc_file" >&2
        return 4
    fi
    exec {_sc_fd}< "$_sc_file" || return 4
    if [[ ! -f /proc/self/fd/$_sc_fd ]]; then
        exec {_sc_fd}<&-
        return 2
    fi
    _sc_size=$(stat -Lc '%s' -- "/proc/self/fd/$_sc_fd") || {
        exec {_sc_fd}<&-
        return 4
    }
    # Reading to NUL detects binary input. Check the byte count on EOF so
    # a short read cannot turn a partial file into a valid config.
    if IFS= read -r -d '' _sc_contents <&"$_sc_fd"; then
        exec {_sc_fd}<&-
        return 2
    fi
    exec {_sc_fd}<&-
    [[ ${#_sc_contents} == "$_sc_size" ]] || return 4
    while IFS= read -r _sc_line; do
        [[ ! $_sc_line =~ [[:cntrl:]] ]] || return 2
        [[ -z $_sc_line || $_sc_line == \#* ]] && continue
        [[ $_sc_line =~ ^([A-Z_]+)=(.*)$ ]] || return 2
        _sc_key=${BASH_REMATCH[1]} _sc_value=${BASH_REMATCH[2]}
        [[ ${_sc_target[$_sc_key]+known} && ! ${_sc_seen[$_sc_key]+duplicate} ]] || return 2
        [[ $_sc_value != *['$`;&|<>()']* ]] || return 2
        _sc_seen[$_sc_key]=1
        _sc_target["$_sc_key"]=$_sc_value
    done <<< "$_sc_contents"
    if [[ ${3-} == complete ]]; then
        for _sc_key in "${!_sc_target[@]}"; do
            [[ ${_sc_seen[$_sc_key]+present} ]] || return 2
        done
    fi
}

sysguard_config_load() {
    (( $# == 3 || $# == 4 )) || return 2
    local -x LC_ALL=C
    local _sc_root=$1 _sc_override=$2 _sc_policy=${4-}
    [[ $_sc_root == /* && ! $_sc_root =~ [[:cntrl:]] && ! $_sc_override =~ [[:cntrl:]] ]] || return 2
    [[ $3 =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ && $3 != _sc_* && $3 != LC_ALL ]] || return 2
    [[ -z $_sc_policy || $_sc_policy == allow-standalone ]] || return 2
    local _sc_attributes _sc_completeness=''
    _sc_attributes=$(declare -p "$3" 2>/dev/null) || return 2
    _sc_attributes=${_sc_attributes#declare -}
    _sc_attributes=${_sc_attributes%% *}
    [[ $_sc_attributes == A || $_sc_attributes == Ax ]] || return 2
    local -n _sc_output=$3
    local _sc_default=${_sc_root%/}/config/defaults.conf
    local _sc_file _sc_key _sc_value _sc_metric _sc_warning _sc_critical _sc_hysteresis
    local -a _sc_files=()
    local -A _sc_values=(
        [CPU_WARNING]='' [CPU_CRITICAL]='' [MEMORY_WARNING]='' [MEMORY_CRITICAL]=''
        [DISK_WARNING]='' [DISK_CRITICAL]='' [DISK_MOUNT]='' [CPU_SAMPLE_SECONDS]=''
        [WATCH_INTERVAL_SECONDS]='' [MAX_DATA_AGE_SECONDS]='' [ALERT_HYSTERESIS_PERCENT]=''
        [LOG_RETENTION_DAYS]='' [EMAIL_TO]='' [MAIL_ENABLED]='' [REPORT_PDF_ENABLED]=''
    )
    # Failed directory traversal must not look like absent defaults or an
    # absent optional override.
    if [[ -d ${_sc_default%/*} && ! -x ${_sc_default%/*} ]]; then
        printf 'sysguard: configuration directory is inaccessible: %s\n' "${_sc_default%/*}" >&2
        return 4
    fi
    if [[ -z $_sc_override ]]; then
        _sc_override=${_sc_root%/}/config/local.conf
        [[ -e $_sc_override || -L $_sc_override ]] || _sc_override=''
    elif [[ $_sc_override != /* ]]; then
        _sc_override=${_sc_root%/}/$_sc_override
    fi
    if [[ -e $_sc_default || -L $_sc_default || $_sc_policy != allow-standalone || -z $2 ]]; then
        if [[ ! -f $_sc_default ]]; then
            printf 'sysguard: missing default config\n' >&2
            return 2
        fi
        _sc_files+=("$_sc_default")
    else
        _sc_completeness=complete
    fi
    if [[ -n $_sc_override && $_sc_override != "$_sc_default" && ! $_sc_override -ef $_sc_default ]]; then
        _sc_files+=("$_sc_override")
    fi
    for _sc_file in "${_sc_files[@]}"; do
        _sysguard_config_read "$_sc_file" _sc_values "$_sc_completeness" || return "$?"
    done

    for _sc_key in CPU_WARNING CPU_CRITICAL MEMORY_WARNING MEMORY_CRITICAL DISK_WARNING DISK_CRITICAL \
        CPU_SAMPLE_SECONDS WATCH_INTERVAL_SECONDS MAX_DATA_AGE_SECONDS ALERT_HYSTERESIS_PERCENT LOG_RETENTION_DAYS; do
        _sc_value=${_sc_values[$_sc_key]}
        # 18 decimal digits are safe even when two intervals are added.
        [[ $_sc_value =~ ^[0-9]{1,18}$ ]] || return 2
        _sc_values[$_sc_key]=$((10#${_sc_value}))
    done
    _sc_hysteresis=${_sc_values[ALERT_HYSTERESIS_PERCENT]}
    (( _sc_hysteresis <= 20 )) || return 2
    for _sc_metric in CPU MEMORY DISK; do
        _sc_warning=${_sc_values[${_sc_metric}_WARNING]}
        _sc_critical=${_sc_values[${_sc_metric}_CRITICAL]}
        (( _sc_warning < _sc_critical && _sc_critical <= 100 &&
            (_sc_hysteresis == 0 || _sc_hysteresis < _sc_warning) )) || return 2
    done
    (( _sc_values[CPU_SAMPLE_SECONDS] > 0 &&
        _sc_values[WATCH_INTERVAL_SECONDS] > _sc_values[CPU_SAMPLE_SECONDS] &&
        _sc_values[MAX_DATA_AGE_SECONDS] >= _sc_values[WATCH_INTERVAL_SECONDS] + _sc_values[CPU_SAMPLE_SECONDS] &&
        _sc_values[LOG_RETENTION_DAYS] > 0 )) || return 2
    [[ ${_sc_values[MAIL_ENABLED]} =~ ^[01]$ && ${_sc_values[REPORT_PDF_ENABLED]} =~ ^[01]$ ]] || return 2

    local _sc_local_part='[A-Za-z0-9][A-Za-z0-9_+-]*(\.[A-Za-z0-9_+-]+)*'
    local _sc_domain='[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+'
    _sc_value=${_sc_values[EMAIL_TO]}
    if [[ -n $_sc_value || ${_sc_values[MAIL_ENABLED]} == 1 ]]; then
        [[ $_sc_value =~ ^${_sc_local_part}@${_sc_domain}$ ]] || return 2
    fi

    _sc_value=${_sc_values[DISK_MOUNT]}
    [[ -n $_sc_value ]] || return 2
    [[ $_sc_value == /* ]] || _sc_value=${_sc_root%/}/$_sc_value
    [[ -d $_sc_value && -x $_sc_value ]] || return 2
    _sc_value=$(CDPATH='' cd -P -- "$_sc_value" && printf '%s.' "$PWD") || return 4
    _sc_value=${_sc_value%.}
    [[ ! $_sc_value =~ [[:cntrl:]] ]] || return 2
    _sc_values[DISK_MOUNT]=$_sc_value

    _sc_output=()
    for _sc_key in "${!_sc_values[@]}"; do
        _sc_output["$_sc_key"]=${_sc_values[$_sc_key]}
    done
    printf 'sysguard: loaded configuration from %s\n' "${_sc_files[@]}" >&2
    return 0
}
