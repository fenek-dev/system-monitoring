# Perf — w5c-perf-after (2026-09-24)

Machine: MacBookPro18,4, Apple M1 Max, 64 GB, macOS 26.5 (25F71).
Budget (ARCHITECTURE §7, advisory): UI closed < 1 % of one core avg, < 80 MB RSS; interactive ≈ 4–5 %.
Build: per section (Debug = scripts/build.sh, Release = perf.sh --release); probe bench in release. Shared machine: other agents run builds/tests concurrently.

## interactive (dashboard: Processes), Release build — 2 min (20:11, commit e9e831c)

- CPU: **7.12 %** of one core (Δ CPU time 8.61 s over 121 s wall, after 30 s warm-up)
- Footprint (budget metric): **min 85.0 / avg 88.2 / max 92.0 MB**; start 92.0 MB → end 89.0 MB
- RSS (incl. shared framework pages): min 167.5 / avg 178.0 / max 186.1 MB (13 samples); start 167.5 MB → end 185.3 MB (drift +17.8 MB)
- Visibility changes logged since launch: 11 (a UI-closed run expects 0; more = someone used the UI)
- Tick periods (LivePipeline log):
  - frame intervals mode=interactive n=60 median=1.00 p95=1.08 max=1.10 s
  - frame intervals mode=interactive n=60 median=1.00 p95=1.07 max=3.84 s
