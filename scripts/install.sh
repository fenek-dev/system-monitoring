#!/usr/bin/env bash
# Release build → ~/Applications/Warden.app (stable path for launch at login, ARCHITECTURE §1).
# Quits a running Warden first. Prints only error:/warning:/BUILD lines plus the install path.
# Rename (Telltale → Warden): an installed ~/Applications/Telltale.app is quit, its login item is unregistered
# (only the old bundle can do that) and carried over to Warden, and the old bundle is removed. Warden itself moves
# the data dir and settings on its first launch (LegacyMigration).
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/gen.sh

DERIVED=.build/xcode-release
BUILT="$DERIVED/Build/Products/Release/Warden.app"
DEST="$HOME/Applications/Warden.app"
LEGACY="$HOME/Applications/Telltale.app"

set +e
xcodebuild -project Warden.xcodeproj -scheme Warden -configuration Release \
    -derivedDataPath "$DERIVED" -destination 'platform=macOS,arch=arm64' build 2>&1 \
    | grep -E 'error:|warning:|BUILD' | tail -40
status=${PIPESTATUS[0]}
set -e
[[ $status -eq 0 ]] || exit "$status"

# PIDs whose executable is exactly $2 (process name $1; string compare, no regex).
pids_of() {
    local p
    for p in $(pgrep -x "$1" || true); do
        [[ "$(ps -o comm= -p "$p" 2>/dev/null)" == "$2" ]] && echo "$p"
    done
    return 0
}
# SIGTERM = the app's graceful ⌘Q path (store flush), then KILL after 5 s.
quit_exact() {
    local pids
    pids=$(pids_of "$1" "$2")
    [[ -z "$pids" ]] && return 0
    kill -TERM $pids 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -z "$(pids_of "$1" "$2")" ]] && break; sleep 0.5; done
    kill -KILL $pids 2>/dev/null || true
}

# Quit only the installed copies (the ones being replaced); worktree Debug builds keep running.
BIN="$DEST/Contents/MacOS/Warden"
quit_exact Warden "$BIN"

legacy_login=0
if [[ -d "$LEGACY" ]]; then
    LEGACY_BIN="$LEGACY/Contents/MacOS/Telltale"
    quit_exact Telltale "$LEGACY_BIN"
    # Only a build that knows --login-item may be asked (an older one would start as a full app and not exit).
    if grep -q -- '--login-item' "$LEGACY_BIN" 2>/dev/null \
        && "$LEGACY_BIN" --login-item status 2>/dev/null | grep -q 'status=enabled'; then
        legacy_login=1
        "$LEGACY_BIN" --login-item unregister >/dev/null 2>&1 || echo "install.sh: could not unregister the Telltale login item" >&2
    fi
    rm -rf "$LEGACY"
    echo "removed:   $LEGACY (login item was $([[ $legacy_login -eq 1 ]] && echo enabled || echo off))"
fi

mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto "$BUILT" "$DEST"
codesign --force --deep --sign - "$DEST" >/dev/null 2>&1 || true
if [[ $legacy_login -eq 1 ]]; then
    "$BIN" --login-item register | tail -1
fi
echo "installed: $DEST"
echo "launch:    open \"$DEST\"   (enable 'Launch at login' in Settings)"
