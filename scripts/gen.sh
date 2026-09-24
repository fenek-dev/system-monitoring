#!/usr/bin/env bash
# Generate Warden.xcodeproj from project.yml (the project is gitignored).
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -f project.yml ]]; then
    echo "gen.sh: project.yml not found (created by W0b); nothing to generate"
    exit 0
fi

xcodegen generate --spec project.yml --quiet
