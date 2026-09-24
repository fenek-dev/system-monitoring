#!/usr/bin/env bash
# Merge gate: build all package targets, build the app, run the given suites,
# and forbid wrapping subtraction (&-) outside RateCalculator.swift.
# Usage: scripts/ci.sh <Suite> [<Suite>…]
set -uo pipefail
cd "$(dirname "$0")/.."

fail() { echo "ci.sh: FAILED — $1"; exit 1; }

echo "== swift build (all targets)"
(cd MonitorCore && swift build --build-tests 2>&1 | grep -E 'error:|warning: |Build complete' | tail -30
 exit "${PIPESTATUS[0]}") || fail "swift build"

echo "== app build"
scripts/build.sh || fail "app build"

if [[ $# -gt 0 ]]; then
    echo "== tests: $*"
    scripts/test.sh "$@" || fail "tests"
fi

echo "== &- grep"
hits=$(grep -rn '&-' MonitorCore/Sources --include='*.swift' | grep -v RateCalculator.swift || true)
if [[ -n "$hits" ]]; then
    echo "$hits" | head -20
    fail "wrapping subtraction &- outside RateCalculator.swift"
fi

echo "== map(Double.init) grep"
# On integer optionals this resolves to Double(bitPattern:) — use `.map { Double($0) }`.
hits=$(grep -rn 'map(Double\.init)' MonitorCore/Sources --include='*.swift' || true)
if [[ -n "$hits" ]]; then
    echo "$hits" | head -20
    fail "map(Double.init) is ambiguous (bitPattern); use .map { Double(\$0) }"
fi

echo "== @unchecked grep"
# Only MonitorMocks may use @unchecked (Sendable escape hatch); elsewhere use OSAllocatedUnfairLock/actors.
hits=$(grep -rn '@unchecked' MonitorCore/Sources MonitorCore/Tests App --include='*.swift' | grep -v '/MonitorMocks/' || true)
if [[ -n "$hits" ]]; then
    echo "$hits" | head -20
    fail "@unchecked outside MonitorMocks"
fi

echo "ci.sh: OK"
