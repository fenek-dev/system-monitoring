#!/usr/bin/env bash
# Quit any running Telltale, then launch the Debug build with a per-worktree data dir.
# Usage: scripts/run.sh [--mock [<scenario>]] [--open-dashboard [<page>]] [--open-popover] [--open-settings]
#                       [--crash-sensor <id>] [other app args…]
#   scripts/run.sh --mock calm        (build first: scripts/build.sh)
# Env passed through when set: TELLTALE_DISABLE_SENSORS, TELLTALE_MOCK.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="$PWD/.build/xcode/Build/Products/Debug/Telltale.app"
DATA="${TELLTALE_DATA_DIR:-$PWD/.build/data}"

if [[ ! -d "$APP" ]]; then
    echo "run.sh: $APP not found; run scripts/build.sh first" >&2
    exit 1
fi

# Quit every running instance (graceful first, so the store flushes), then make sure they are gone.
if pgrep -x Telltale >/dev/null; then
    osascript -e 'tell application id "dev.telltale.Telltale" to quit' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Telltale >/dev/null || break; sleep 0.5; done
    pkill -x Telltale 2>/dev/null || true
fi

mkdir -p "$DATA"
envs=(--env "TELLTALE_DATA_DIR=$DATA")
[[ -n "${TELLTALE_DISABLE_SENSORS:-}" ]] && envs+=(--env "TELLTALE_DISABLE_SENSORS=$TELLTALE_DISABLE_SENSORS")
[[ -n "${TELLTALE_MOCK:-}" ]] && envs+=(--env "TELLTALE_MOCK=$TELLTALE_MOCK")

open -n "${envs[@]}" "$APP" --args "$@"
sleep 1
pid=$(pgrep -nx Telltale || true)
echo "run.sh: Telltale pid=${pid:-?} data=$DATA args=$*"
