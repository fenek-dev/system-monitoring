#!/usr/bin/env bash
# Build telltale-probe (release unless PROBE_CONFIG=debug) and run it with the given arguments.
# Usage: scripts/probe.sh --list | --sensor <id> [--ticks N] | --bench [--ticks 60] | --frames | --record <file>
#        scripts/probe.sh --maintain-now [--data-dir <dir>]      (see: scripts/probe.sh --help)
# Relative --record/--dump paths resolve against the repo root.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
CONFIG="${PROBE_CONFIG:-release}"

set +e
build=$(cd MonitorCore && swift build -c "$CONFIG" --product telltale-probe 2>&1)
status=$?
set -e
if [[ $status -ne 0 ]]; then
    echo "$build" | grep -E 'error:' | head -20
    exit "$status"
fi
BIN="$(cd MonitorCore && swift build -c "$CONFIG" --show-bin-path)/telltale-probe"
exec "$BIN" "$@"
