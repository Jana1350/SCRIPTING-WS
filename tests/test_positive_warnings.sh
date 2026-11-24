#!/usr/bin/env bash
# Run separately until the proposed positive-warning contract is adopted.
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
# shellcheck source=scripts/config.sh
source "$root/scripts/config.sh"
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
declare -A settings=()
failed=0
for metric in CPU MEMORY DISK; do
    printf '%s\n' ALERT_HYSTERESIS_PERCENT=0 "${metric}_WARNING=1" > "$d/override"
    sysguard_config_load "$root" "$d/override" settings
    [[ ${settings[${metric}_WARNING]} == 1 ]]
    printf '%s\n' ALERT_HYSTERESIS_PERCENT=0 "${metric}_WARNING=0" > "$d/override"
    rc=0
    sysguard_config_load "$root" "$d/override" settings || rc=$?
    if [[ $rc != 2 ]]; then echo "$metric zero warning: expected 2, got $rc" >&2; failed=1; fi
done
exit "$failed"
