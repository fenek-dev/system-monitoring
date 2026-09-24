# Perf — w5c-perf-before (2026-09-24)

Machine: MacBookPro18,4, Apple M1 Max, 64 GB, macOS 26.5 (25F71).
Budget (ARCHITECTURE §7, advisory): UI closed < 1 % of one core avg, < 80 MB RSS; interactive ≈ 4–5 %.
Build: per section (Debug = scripts/build.sh, Release = perf.sh --release); probe bench in release. Shared machine: other agents run builds/tests concurrently.

## interactive (dashboard: Processes), Release build — 2 min (20:01, commit 7de15e3)

- CPU: **5.25 %** of one core (Δ CPU time 6.41 s over 122 s wall, after 30 s warm-up)
- Footprint (budget metric): **min 84.0 / avg 91.7 / max 99.0 MB**; start 92.0 MB → end 88.0 MB
- RSS (incl. shared framework pages): min 162.1 / avg 172.3 / max 179.5 MB (13 samples); start 164.1 MB → end 179.0 MB (drift +14.9 MB)
- Visibility changes logged since launch: 5 (a UI-closed run expects 0; more = someone used the UI)
- Tick periods (LivePipeline log):
  - frame intervals mode=interactive n=60 median=1.00 p95=1.06 max=4.96 s
