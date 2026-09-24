# Perf — e-overview-before (2026-09-24)

Machine: MacBookPro18,4, Apple M1 Max, 64 GB, macOS 26.5 (25F71).
Budget (ARCHITECTURE §7, advisory): UI closed < 1 % of one core avg, < 80 MB RSS; interactive ≈ 4–5 %.
Build: per section (Debug = scripts/build.sh, Release = perf.sh --release); probe bench in release. Shared machine: other agents run builds/tests concurrently.

## interactive (dashboard: Overview), Release build — 2 min (22:54, commit 1e0bf84)

- CPU: **4.76 %** of one core (Δ CPU time 5.81 s over 122 s wall, after 30 s warm-up)
- Footprint (budget metric): **min 53.0 / avg 63.5 / max 74.0 MB**; start 74.0 MB → end 64.0 MB
- RSS (incl. shared framework pages): min 121.4 / avg 124.3 / max 125.3 MB (13 samples); start 121.4 MB → end 125.3 MB (drift +3.9 MB)
- Visibility changes logged since launch: 13 (a UI-closed run expects 0; more = someone used the UI)
- Tick periods (LivePipeline log):
  - frame intervals mode=interactive n=60 median=1.00 p95=1.07 max=1.10 s
  - frame intervals mode=interactive n=60 median=1.00 p95=2.06 max=2.95 s

> Agent E note: the dashboard window was occluded several times during this run (13 visibility changes; the
> log shows ~6 background stretches of 2–25 s between 22:51:57 and 22:54:12), so this is a *lower bound* for the
> baseline, not a clean comparison with e-overview-after (visible the whole run). Four later baseline reruns at
> 1e0bf84 never got the window on screen (0 visibility changes, 0.9–1.1 % = background) and were discarded.
