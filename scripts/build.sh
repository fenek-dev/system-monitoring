#!/usr/bin/env bash
# Generate the Xcode project and build the Warden app (Debug, arm64).
# Prints only error:/warning:/BUILD lines plus the app path.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -f project.yml ]]; then
    echo "build.sh: project.yml not found (created by W0b); skipping app build"
    exit 0
fi

scripts/gen.sh

DERIVED=.build/xcode
APP="$DERIVED/Build/Products/Debug/Warden.app"

set +e
xcodebuild -project Warden.xcodeproj -scheme Warden -configuration Debug \
    -derivedDataPath "$DERIVED" -destination 'platform=macOS,arch=arm64' build 2>&1 \
    | grep -E 'error:|warning:|BUILD' | tail -40
status=${PIPESTATUS[0]}
set -e

if [[ $status -eq 0 ]]; then
    echo "app: $PWD/$APP"
fi
exit "$status"
