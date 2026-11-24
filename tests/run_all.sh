#!/usr/bin/env bash
set -eu -o pipefail

tests=$(cd -P -- "$(dirname -- "$0")" && pwd -P)
fixture=$tests/fixtures/v1/metrics.csv
# C9 defines the sample values as well as the CSV schema. Check both before
# running any suite, including consumers that rely on those threshold crossings.
if ! awk '
    /^## C9\./ { section = 1; next }
    section && /^```csv$/ { copying = 1; next }
    copying && /^```$/ { complete = 1; exit }
    copying { print }
    END { if (!complete) exit 1 }
' "$tests/../docs/CONTRACTS.md" | cmp -s -- - "$fixture"; then
    printf 'FAIL: missing or incompatible v1/metrics.csv (expected contract C9)\n' >&2
    exit 3
fi

passed=0
for suite in test_monitor test_alerts test_cron test_reports test_rotation test_setup test_positive_warnings; do
    bash "$tests/$suite.sh" || {
        status=$?
        printf 'FAIL: %s.sh exited %d\n' "$suite" "$status" >&2
        exit "$status"
    }
    passed=$((passed + 1))
done
printf 'Suites: %d passed, 0 skipped\n' "$passed"
