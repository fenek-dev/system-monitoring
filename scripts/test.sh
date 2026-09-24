#!/usr/bin/env bash
# Run MonitorCore tests matching each filter; prints every recorded issue plus the tail of each run.
# Usage: scripts/test.sh <filter> [<filter>…]   e.g. scripts/test.sh MonitorModelTests
set -uo pipefail
cd "$(dirname "$0")/../MonitorCore"

if [[ $# -eq 0 ]]; then
    echo "usage: scripts/test.sh <filter> [<filter>…]" >&2
    exit 2
fi

log=$(mktemp -t telltale-test)
trap 'rm -f "$log"' EXIT

failed=0
for filter in "$@"; do
    echo "== swift test --filter $filter"
    swift test --filter "$filter" >"$log" 2>&1
    status=$?
    # The tail alone hides failures reported early in a long run: list every issue first
    # (known issues print as "recorded a known issue" and are not listed).
    issues=$(grep -E 'recorded an issue' "$log" || true)
    if [[ -n "$issues" ]]; then
        echo "-- issues ($(echo "$issues" | wc -l | tr -d ' ')):"
        echo "$issues" | head -60
        echo "--"
    fi
    tail -25 "$log"
    # A filter that matches nothing "passes" with zero tests (a typo'd suite name); count both frameworks' runs.
    ran=$(grep -Eo 'Test run with [0-9]+ tests?|Executed [0-9]+ tests?' "$log" | grep -Eo '[0-9]+' \
        | awk '{ s += $1 } END { print s + 0 }')
    if [[ $status -ne 0 ]]; then
        echo "== FAILED: $filter (exit $status)"
        failed=1
    elif [[ $ran -eq 0 ]]; then
        echo "== FAILED: $filter ran zero tests (no test matches the filter)"
        failed=1
    fi
done
exit "$failed"
