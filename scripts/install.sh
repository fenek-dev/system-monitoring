#!/usr/bin/env bash
# Release build → ~/Applications/Telltale.app (stable path for launch at login, ARCHITECTURE §1).
# Quits a running Telltale first. Prints only error:/warning:/BUILD lines plus the install path.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/gen.sh

DERIVED=.build/xcode-release
BUILT="$DERIVED/Build/Products/Release/Telltale.app"
DEST="$HOME/Applications/Telltale.app"

set +e
xcodebuild -project Telltale.xcodeproj -scheme Telltale -configuration Release \
    -derivedDataPath "$DERIVED" -destination 'platform=macOS,arch=arm64' build 2>&1 \
    | grep -E 'error:|warning:|BUILD' | tail -40
status=${PIPESTATUS[0]}
set -e
[[ $status -eq 0 ]] || exit "$status"

# Quit only the installed copy (the one being replaced); worktree Debug builds keep running.
BIN="$DEST/Contents/MacOS/Telltale"
installed_pids() {                                          # exact executable path, no regex
    local p
    for p in $(pgrep -x Telltale || true); do
        [[ "$(ps -o comm= -p "$p" 2>/dev/null)" == "$BIN" ]] && echo "$p"
    done
    return 0
}
pids=$(installed_pids)
if [[ -n "$pids" ]]; then
    kill -TERM $pids 2>/dev/null || true                    # SIGTERM = the app's graceful ⌘Q path
    for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -z "$(installed_pids)" ]] && break; sleep 0.5; done
    kill -KILL $pids 2>/dev/null || true
fi

mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto "$BUILT" "$DEST"
codesign --force --deep --sign - "$DEST" >/dev/null 2>&1 || true
echo "installed: $DEST"
echo "launch:    open \"$DEST\"   (enable 'Launch at login' in Settings)"
