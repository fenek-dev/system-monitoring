#!/usr/bin/env bash
# Render a screen (ScreenCatalog × MockScenario) at @2x with telltale-render.
# Usage: scripts/render.sh <screen> [scenario] [extra telltale-render args…]
#        scripts/render.sh --gallery | --component <id> | --list  (passed through)
# Output: MonitorCore/.build/renders/<screen>-<scenario>.png
set -euo pipefail
cd "$(dirname "$0")/../MonitorCore"

if [[ $# -eq 0 ]]; then
    echo "usage: scripts/render.sh <screen> [scenario] [telltale-render args…]" >&2
    exit 2
fi

if ! log="$(swift build --product telltale-render 2>&1)"; then
    echo "$log" | grep -E 'error:' | head -20
    exit 1
fi
BIN="$(swift build --product telltale-render --show-bin-path)/telltale-render"

if [[ "$1" == --* ]]; then
    exec "$BIN" "$@"
fi

screen="$1"; shift
scenario="${1:-calm}"; [[ $# -gt 0 ]] && shift
exec "$BIN" --screen "$screen" --scenario "$scenario" "$@"
