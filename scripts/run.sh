#!/usr/bin/env bash
# Quit this worktree's running Telltale (only this build's binary, never other worktrees or the installed app),
# then launch the Debug build with a per-worktree data dir.
# Usage: scripts/run.sh [--mock [<scenario>]] [--open-dashboard [<page>]] [--open-popover] [--open-settings]
#                       [--crash-sensor <id>] [--status-preview elevated|critical] [other app args…]
#   scripts/run.sh --mock calm        (build first: scripts/build.sh)
#   scripts/run.sh --stop             only quit this build's instance
# Every TELLTALE_* env var is passed through (TELLTALE_DISABLE_SENSORS, TELLTALE_MOCK, DEBUG
# TELLTALE_POPOVER_CYCLES=N, TELLTALE_VISIBILITY_DRILL=1 …); TELLTALE_DATA_DIR defaults to
# ~/Library/Caches/dev.telltale-dev/<worktree dir name>.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="$PWD/.build/xcode/Build/Products/Debug/Telltale.app"
BIN="$APP/Contents/MacOS/Telltale"
# Never under ~/Documents (TCC prompts block file I/O): per-worktree dir in the user's caches (ruling).
DATA="${TELLTALE_DATA_DIR:-$HOME/Library/Caches/dev.telltale-dev/$(basename "$PWD")}"

# PIDs whose executable is exactly $BIN (string compare, no regex: paths contain '.', '+', …).
pids_of_this_build() {
    local p
    for p in $(pgrep -x Telltale || true); do
        [[ "$(ps -o comm= -p "$p" 2>/dev/null)" == "$BIN" ]] && echo "$p"
    done
    return 0
}

# Graceful quit: SIGTERM takes the app's ⌘Q path (store flush ≤ 3 s), then KILL.
stop_this_build() {
    local pids
    pids=$(pids_of_this_build)
    [[ -z "$pids" ]] && return 0
    kill -TERM $pids 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        [[ -z "$(pids_of_this_build)" ]] && return 0
        sleep 0.5
    done
    kill -KILL $pids 2>/dev/null || true
}

stop_this_build
if [[ "${1:-}" == "--stop" ]]; then
    echo "run.sh: stopped"
    exit 0
fi

if [[ ! -d "$APP" ]]; then
    echo "run.sh: $APP not found; run scripts/build.sh first" >&2
    exit 1
fi

mkdir -p "$DATA"
envs=(--env "TELLTALE_DATA_DIR=$DATA")
while IFS='=' read -r name value; do
    [[ "$name" == TELLTALE_* && "$name" != TELLTALE_DATA_DIR ]] && envs+=(--env "$name=$value")
done < <(env)

open -n "${envs[@]}" "$APP" --args "$@"
sleep 1
pid=$(pids_of_this_build | tail -1)
echo "run.sh: Telltale pid=${pid:-?} data=$DATA args=$*"
