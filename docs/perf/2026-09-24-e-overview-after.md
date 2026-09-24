# Perf — e-overview-after (2026-09-24)

Machine: MacBookPro18,4, Apple M1 Max, 64 GB, macOS 26.5 (25F71).
Budget (ARCHITECTURE §7, advisory): UI closed < 1 % of one core avg, < 80 MB RSS; interactive ≈ 4–5 %.
Build: per section (Debug = scripts/build.sh, Release = perf.sh --release); probe bench in release. Shared machine: other agents run builds/tests concurrently.

## interactive (dashboard: Overview), Release build — 2 min (23:20, commit 65298cd)

- CPU: **5.40 %** of one core (Δ CPU time 6.54 s over 121 s wall, after 30 s warm-up)
- Footprint (budget metric): **min 56.0 / avg 62.4 / max 71.0 MB**; start 60.0 MB → end 63.0 MB
- RSS (incl. shared framework pages): min 117.7 / avg 119.9 / max 121.2 MB (13 samples); start 117.9 MB → end 121.3 MB (drift +3.4 MB)
- Visibility changes logged since launch: 1 (a UI-closed run expects 0; more = someone used the UI)
- Tick periods (LivePipeline log):
  - frame intervals mode=interactive n=60 median=1.00 p95=1.06 max=1.07 s
  - frame intervals mode=interactive n=60 median=1.00 p95=1.06 max=1.10 s
