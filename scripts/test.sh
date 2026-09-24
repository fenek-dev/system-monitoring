#!/usr/bin/env bash
# Run MonitorCore tests matching each filter; prints the tail of each run.
# Usage: scripts/test.sh <filter> [<filter>…]   e.g. scripts/test.sh MonitorModelTests
set -uo pipefail
cd "$(dirname "$0")/../MonitorCore"

if [[ $# -eq 0 ]]; then
    echo "usage: scripts/test.sh <filter> [<filter>…]" >&2
    exit 2
fi

failed=0
for filter in "$@"; do
    echo "== swift test --filter $filter"
    swift test --filter "$filter" 2>&1 | tail -25
    status=${PIPESTATUS[0]}
    if [[ $status -ne 0 ]]; then
        echo "== FAILED: $filter (exit $status)"
        failed=1
    fi
done
exit "$failed"
