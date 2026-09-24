# Perf — w5c-perf-before-mock (2026-09-24)

Machine: MacBookPro18,4, Apple M1 Max, 64 GB, macOS 26.5 (25F71).
Budget (ARCHITECTURE §7, advisory): UI closed < 1 % of one core avg, < 80 MB RSS; interactive ≈ 4–5 %.
Build: per section (Debug = scripts/build.sh, Release = perf.sh --release); probe bench in release. Shared machine: other agents run builds/tests concurrently.

## interactive (dashboard: Processes), mock restricted, Release build — 2 min (20:18, commit e9e831c)

- CPU: **7.54 %** of one core (Δ CPU time 9.12 s over 121 s wall, after 30 s warm-up)
- Footprint (budget metric): **min 41.0 / avg 50.4 / max 58.0 MB**; start 44.0 MB → end 58.0 MB
- RSS (incl. shared framework pages): min 113.9 / avg 126.8 / max 134.0 MB (13 samples); start 113.9 MB → end 134.0 MB (drift +20.1 MB)
- Visibility changes logged since launch: 6 (a UI-closed run expects 0; more = someone used the UI)
