# Perf — w5c-perf-after-mock (2026-09-24)

Machine: MacBookPro18,4, Apple M1 Max, 64 GB, macOS 26.5 (25F71).
Budget (ARCHITECTURE §7, advisory): UI closed < 1 % of one core avg, < 80 MB RSS; interactive ≈ 4–5 %.
Build: per section (Debug = scripts/build.sh, Release = perf.sh --release); probe bench in release. Shared machine: other agents run builds/tests concurrently.

## interactive (dashboard: Processes), mock restricted, Release build — 2 min (20:14, commit e9e831c)

- CPU: **2.19 %** of one core (Δ CPU time 2.65 s over 121 s wall, after 30 s warm-up)
- Footprint (budget metric): **min 43.0 / avg 43.7 / max 44.0 MB**; start 43.0 MB → end 44.0 MB
- RSS (incl. shared framework pages): min 117.6 / avg 118.7 / max 119.3 MB (13 samples); start 117.6 MB → end 119.2 MB (drift +1.6 MB)
- Visibility changes logged since launch: 12 (a UI-closed run expects 0; more = someone used the UI)
