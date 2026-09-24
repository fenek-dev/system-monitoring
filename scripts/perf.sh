#!/usr/bin/env bash
# Measure this worktree's Telltale (Debug build from scripts/build.sh) and append a section to docs/perf/<date>-<cp>.md.
# Usage: scripts/perf.sh <minutes> [--interactive] [--mock <scenario>] [--release] [--cp <name>] [--warmup <s>]
#                        [--no-bench] [--keep]
#   --release: Release build in .build/xcode-release (launched/stopped by exact path), else scripts/run.sh's Debug app
#   scripts/perf.sh 10                  UI closed (background, 5 s cadence), live sensors
#   scripts/perf.sh 2 --interactive     dashboard open on Processes (interactive, 1 s)
#   scripts/perf.sh 5 --mock calm       mock pipeline (UI + model cost without sensors)
# CPU % = Δ(process CPU time) / Δ(wall) over the window after warm-up (100 % = one core); RSS sampled every 10 s.
# Only this worktree's instance is launched/stopped (scripts/run.sh PID targeting). Advisory: report, don't tune.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

minutes="${1:-}"
[[ "$minutes" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "usage: scripts/perf.sh <minutes> [--interactive] [--mock <s>] [--cp <name>]" >&2; exit 2; }
shift
interactive=0; mock=""; cp="adhoc"; warmup=30; bench=1; keep=0; release=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --interactive) interactive=1 ;;
        --release) release=1 ;;
        --mock) mock="$2"; shift ;;
        --cp) cp="$2"; shift ;;
        --warmup) warmup="$2"; shift ;;
        --no-bench) bench=0 ;;
        --keep) keep=1 ;;
        *) echo "perf.sh: unknown argument $1" >&2; exit 2 ;;
    esac
    shift
done

mode="background (UI closed)"
args=()
if [[ $interactive -eq 1 ]]; then mode="interactive (dashboard: Processes)"; args+=(--open-dashboard processes); fi
if [[ -n "$mock" ]]; then mode="$mode, mock $mock"; args+=(--mock "$mock"); fi

# cputime "[[dd-]hh:]mm:ss.cs" → seconds
cpu_seconds() {
    ps -o cputime= -p "$1" 2>/dev/null | awk '{
        s = $1; d = 0
        if (index(s, "-")) { split(s, a, "-"); d = a[1]; s = a[2] }
        n = split(s, p, ":"); t = 0
        for (i = 1; i <= n; i++) t = t * 60 + p[i]
        printf "%.2f\n", t + d * 86400 }'
}
rss_mb() { ps -o rss= -p "$1" 2>/dev/null | awk '{ printf "%.1f\n", $1 / 1024 }'; }

if [[ $release -eq 1 ]]; then
    # Release build in its own derived-data dir; launched and stopped by exact binary path (never other instances).
    REL="$ROOT/.build/xcode-release/Build/Products/Release/Telltale.app"
    REL_BIN="$REL/Contents/MacOS/Telltale"
    scripts/gen.sh >/dev/null
    xcodebuild -project Telltale.xcodeproj -scheme Telltale -configuration Release -derivedDataPath .build/xcode-release \
        -destination 'platform=macOS,arch=arm64' build 2>&1 | grep -E 'error:|BUILD' | tail -3
    stop_release() {
        local p
        for p in $(pgrep -x Telltale || true); do
            [[ "$(ps -o comm= -p "$p" 2>/dev/null)" == "$REL_BIN" ]] && kill -TERM "$p" 2>/dev/null
        done
        sleep 4
    }
    stop_release
    scripts/run.sh --stop >/dev/null
    DATA="${TELLTALE_DATA_DIR:-$HOME/Library/Caches/dev.telltale-dev/$(basename "$ROOT")}"
    mkdir -p "$DATA"
    open -n --env "TELLTALE_DATA_DIR=$DATA" "$REL" --args ${args[@]+"${args[@]}"}
    sleep 2
    pid=""
    for p in $(pgrep -x Telltale || true); do
        [[ "$(ps -o comm= -p "$p" 2>/dev/null)" == "$REL_BIN" ]] && pid="$p"
    done
    mode="$mode, Release build"
else
    line=$(scripts/run.sh ${args[@]+"${args[@]}"} | tail -1)
    pid=$(echo "$line" | sed -n 's/.*pid=\([0-9]*\).*/\1/p')
    mode="$mode, Debug build"
fi
[[ -n "$pid" ]] || { echo "perf.sh: app did not start" >&2; exit 1; }
echo "perf.sh: pid $pid, $mode; warm-up ${warmup}s, then ${minutes} min"
sleep "$warmup"

start_wall=$(date +%s)
start_cpu=$(cpu_seconds "$pid")
rss_first=$(rss_mb "$pid")
rss_samples=("$rss_first")
end_at=$(awk -v s="$start_wall" -v m="$minutes" 'BEGIN { printf "%d", s + m * 60 }')
while [[ $(date +%s) -lt $end_at ]]; do
    sleep 10
    kill -0 "$pid" 2>/dev/null || { echo "perf.sh: app exited during the run" >&2; exit 1; }
    rss_samples+=("$(rss_mb "$pid")")
done
end_wall=$(date +%s)
end_cpu=$(cpu_seconds "$pid")
rss_last=$(rss_mb "$pid")

cpu_pct=$(awk -v a="$start_cpu" -v b="$end_cpu" -v w0="$start_wall" -v w1="$end_wall" 'BEGIN { printf "%.2f", (b - a) / (w1 - w0) * 100 }')
rss_stats=$(printf '%s\n' "${rss_samples[@]}" | awk 'NR == 1 { mn = $1; mx = $1 } { s += $1; if ($1 < mn) mn = $1; if ($1 > mx) mx = $1 }
    END { printf "min %.1f / avg %.1f / max %.1f MB (%d samples)", mn, s / NR, mx, NR }')
drift=$(awk -v a="$rss_first" -v b="$rss_last" 'BEGIN { printf "%+.1f", b - a }')
since_min=$(( ($(date +%s) - start_wall) / 60 + 2 ))
intervals=$(/usr/bin/log show --last "${since_min}m" --style compact \
    --predicate "processID == $pid AND subsystem == \"dev.telltale\" AND category == \"Runtime\"" 2>/dev/null \
    | grep -o 'frame intervals.*' | tail -4 || true)

visibility=$(/usr/bin/log show --last "${since_min}m" --style compact \
    --predicate "processID == $pid AND subsystem == \"dev.telltale\" AND category == \"Visibility\"" 2>/dev/null \
    | grep -c 'mode=' || true)
echo "perf.sh: CPU ${cpu_pct} % of one core over $((end_wall - start_wall)) s; RSS ${rss_stats}; drift ${drift} MB"
echo "perf.sh: visibility changes during the run (incl. launch): ${visibility}"
[[ -n "$intervals" ]] && echo "$intervals"

bench_out=""
if [[ $bench -eq 1 && -z "$mock" ]]; then
    bench_mode=background; [[ $interactive -eq 1 ]] && bench_mode=interactive
    bench_out=$(scripts/probe.sh --bench --ticks 30 --interval 1 --mode "$bench_mode" 2>&1 | tail -45)
fi
if [[ $keep -eq 0 ]]; then
    if [[ $release -eq 1 ]]; then stop_release; else scripts/run.sh --stop >/dev/null; fi
fi

mkdir -p docs/perf
out="docs/perf/$(date +%Y-%m-%d)-${cp}.md"
if [[ ! -f "$out" ]]; then
    {
        echo "# Perf — ${cp} ($(date +%Y-%m-%d))"
        echo
        echo "Machine: $(sysctl -n hw.model), $(sysctl -n machdep.cpu.brand_string), $(( $(sysctl -n hw.memsize) / 1073741824 )) GB, macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))."
        echo "Budget (ARCHITECTURE §7, advisory): UI closed < 1 % of one core avg, < 80 MB RSS; interactive ≈ 4–5 %."
        echo "Build: per section (Debug = scripts/build.sh, Release = perf.sh --release); probe bench in release. Shared machine: other agents run builds/tests concurrently."
    } > "$out"
fi
{
    echo
    echo "## ${mode} — ${minutes} min ($(date +%H:%M), commit $(git rev-parse --short HEAD))"
    echo
    echo "- CPU: **${cpu_pct} %** of one core (Δ CPU time $(awk -v a="$start_cpu" -v b="$end_cpu" 'BEGIN { printf "%.2f", b - a }') s over $((end_wall - start_wall)) s wall, after ${warmup} s warm-up)"
    echo "- RSS: ${rss_stats}; start ${rss_first} MB → end ${rss_last} MB (drift ${drift} MB)"
    echo "- Visibility changes logged since launch: ${visibility} (a UI-closed run expects 0; more = someone used the UI)"
    if [[ -n "$intervals" ]]; then
        echo "- Tick periods (LivePipeline log):"
        echo "$intervals" | sed 's/^/  - /'
    fi
    if [[ -n "$bench_out" ]]; then
        echo
        echo "<details><summary>telltale-probe --bench --ticks 30 (${bench_mode})</summary>"
        echo
        echo '```'
        echo "$bench_out"
        echo '```'
        echo "</details>"
    fi
} >> "$out"
echo "perf.sh: wrote $out"
