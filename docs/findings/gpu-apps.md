# M0 Findings (M1 Max, macOS 26.5)

## gpu-apps — AGXDeviceUserClient

- Status: ✅. Public IOKit only (`AGXAccelerator` service, `IORegistryEntryGetChildIterator`), no private declarations needed.
- Creator format: `IOUserClientCreator` is a string `"pid 123, ProcessName"` (confirmed on this machine, e.g. `"pid 98391, Browser Helper"`). Parsed by splitting on the first comma; pid is the token after `"pid "`.
- Time key: per-client `AppUsage` is an array of dicts, each with `accumulatedGPUTime` (an `NSNumber`, units **nanoseconds** — confirmed by delta-ing two 1 s-apart samples and dividing by 1e9 to get a plausible 0–100%+ "percent of one GPU" number that tracked real load, see below).
- Walk cost: `walkCost=0.001714875 seconds` / `0.002215916 seconds` across two runs, ~67-68 user clients on this machine. Cheap enough to poll every 1s tick.
- Device Utilization % key present? **Yes** — `PerformanceStatistics["Device Utilization %"]` exists and is a live 0–100 integer. Confirmed it responds to real load: **43 → 86** when the spike's own 5s Metal compute busy-loop (`--load`) started. This is a good fallback/cross-check for total GPU% independent of summing per-client `AppUsage` deltas, and doesn't depend on `IOReport` GPUPH channels at all (this spike never touches `IOReport`).
- Full `PerformanceStatistics` key set observed: `Alloc system memory, Allocated PB Size, Device Utilization %, In use system memory, In use system memory (driver), Renderer Utilization %, SplitSceneCount, TiledSceneBytes, Tiler Utilization %, lastRecoveryTime, recoveryCount`.
  - **Renderer Utilization %** and **Tiler Utilization %**: present, both tracked `Device Utilization %` almost exactly in this run (42/43 idle, 86/86/86 under load) — on this TBDR GPU they appear to move together; no case observed yet where they diverge meaningfully, but both are cheap to record alongside Device Utilization %.
  - GPU memory keys: **`Alloc system memory`** (bytes, e.g. 4,995,334,144 ≈ 4.65 GiB) and **`In use system memory`** (bytes, e.g. 1,025,212,416 ≈ 977 MiB) are the two GPU-memory-relevant keys. `In use system memory` is the one that best matches "system GPU memory in use" the design wants — it dropped slightly under load in this sample run (noise / allocator churn, not a bug) while `Alloc system memory` (the pool reserved, not necessarily resident) also fluctuated. **`In use system memory (driver)` was 0 in every sample** — looks unused/always-zero on this OS build, not a reliable second source. `Allocated PB Size` / `TiledSceneBytes` are tiler-internal (parameter-buffer / tile scene bytes), not general GPU memory — probably not what the design wants but noted for completeness.
  - These are all machine-/OS-version-specific undocumented dictionary keys (no headers, no docs) — should be treated as best-effort and re-verified per OS release, same caveat as other private-API spikes in this repo.
- Needs responsible-PID grouping? **Yes, confirmed.** Ran the `AppUsage` walk against real running apps (not synthetic): Chrome/Arc-style and Electron-style GPU helper processes show up as distinct clients under their **own** helper PID, not the app's main PID:
  - `Browser Helper [98391]` → `responsibility_get_pid_responsible_for_pid` maps it to `98386` (Arc's main process).
  - `Claude Helper [55511]` → maps to `55507` (Claude desktop app's main process).
  - `Discord Helper [54973]` → maps to `54970` (Discord's main process).
  - `Codex (Service) [44445]` → maps to `44436`.
  - Without this grouping, per-app GPU% would under-count/misattribute browser and Electron-app GPU cost to an opaque helper PID instead of the user-facing app. `libSystem`'s `responsibility_get_pid_responsible_for_pid` (declared locally in `CPrivate/include/Responsibility.h`, already used elsewhere in this repo for CPU grouping) works for this too — same grouping mechanism as the CPU-side spike (see `docs/findings/procs.md`), so GPU and CPU per-app grouping can share one pid→responsible-pid resolution path.
  - Caveat: an unbundled CLI binary launched directly from a shell (this spike itself, run via `swift run`) reported its own responsible pid as its parent shell/terminal process, not itself (`spike-gpu-apps [75653] -> responsible pid 58909`, the launching terminal process) — expected: `responsibility_*` walks up through non-bundled parents rather than self-terminating at a plain executable. Not an issue for real `.app` targets (WindowServer, Finder, Spotlight, ControlCenter, loginwindow, Arc all correctly resolved to themselves as their own responsible pid), only worth remembering when testing with ad-hoc CLI tools instead of real `.app`s.

### GPU load generator (`--load`)

No browser available in this sandboxed environment, so `spike-gpu-apps --load` spawns a background thread running a busy `MTLComputeCommandEncoder` loop (up to 4 command buffers in flight, ~20000 FMA iterations/thread over a 1M-element buffer) for 5s, then the normal AGX-client sample runs concurrently with it.

Verified:
- The spike's **own PID** appears with a high %: `spike-gpu-apps [75653]  60.1 %` while the load was running (0% / absent-from-top-10 without `--load`).
- **WindowServer** appears in both runs (`14.0 %` idle-ish, `18.0 %` under load) — compositing the desktop always costs something, as expected.
- `Device Utilization %` jumped `43 → 86` in lockstep with starting the load, corroborating the per-client `AppUsage` deltas independently.

No Activity Monitor GUI cross-check was possible in this headless agent environment (no screen/GUI access, same limitation noted in `docs/findings/procs.md`), and `sudo powermetrics` is unavailable here too (`sudo: a password is required`, no interactive TTY). The Device-Utilization-%-tracks-the-load-toggle result above is used as the corroborating signal instead.

### Production requirements

These apply to any real (long-running, tick-based) implementation of per-app GPU%, not just this one-shot spike:

1. **Counter reset / recreated client.** `accumulatedGPUTime` is a per-client monotonic counter, but the client itself can be torn down and recreated (context reset, app relaunch, GPU driver recovery) between two ticks. If the new reading is *lower* than the previous baseline for that pid, do **not** compute `new &- old` (wrapping subtraction on an unsigned type turns a small negative delta into a huge near-`UInt64.max` value — a real bug in the original spike code). **A decreasing counter means the baseline is stale: reset the baseline to the new value and report 0 for that tick, never wrap.** Fixed in the spike: `main.swift`'s per-tick row computation now has `guard v.1 >= old.1 else { return (name, 0) }` before the subtraction, and the comment marks it as the fix for this finding.
2. **Appearing clients.** A client (pid) that has no entry in the previous tick's baseline map is *new this tick* — it must be added to the baseline map with its current counter value and reported as **0** for this tick (not skipped from the baseline, not compared against a synthetic zero — that would produce one huge false spike from "startup" as if the app had been running since forever). It becomes eligible for a real delta starting the *next* tick. The spike's two-sample model already does this (`guard let old = a[pid] else { return nil }` — no row is emitted for a client absent from the older sample), but a continuous sensor must carry the same rule forward: keep one persistent `[pid: (name, ns)]` baseline dict across ticks, insert-without-reporting on first sight, delta-and-report from the second sighting on.
   - **Identity is `pid` + creator name, not `pid` alone**, because pids are reused by the OS. If the same pid shows a *different* creator-name string than the stored baseline, that pid was recycled to a new process — treat it exactly like an appearing client (reset the baseline, report 0, do not diff against the old process's accumulated time). Fixed in the spike: `guard old.0 == v.0 else { return nil }` before the subtraction.
3. **Sum-vs-Device-Utilization-% cross-check (measured).** Added a print of the sum of *all* per-client deltas (not just the printed top 10) alongside `Device Utilization %` sampled at the same instant (right after the second `gpuTimes()` walk). Three runs on this machine:

   | condition | sum of all per-client % | Device Utilization % (same instant) |
   |---|---|---|
   | idle | 25.1 % | 21 % |
   | `--load` running | 100.5 % | 100 % |
   | `--load` running (2nd run) | 101.0 % | 100 % |

   The sum tracks `Device Utilization %` closely (within ~1-4 points) in all three runs, including saturating together near 100. **`Device Utilization %` is a 0–100 measure of the whole GPU (one accelerator, not per-client-independent), and the per-client percentages are shares of that same 0–100 whole** — they are not each independently capable of reaching 100%. The sum can slightly *exceed* 100% (100.5%, 101.0%) rather than exactly match; this is sampling skew, not double counting or a modeling error: the per-client sum is an integral of `accumulatedGPUTime` deltas over the exact ~1s window between the two `gpuTimes()` calls, while `Device Utilization %` is a separately-maintained driver counter read once, at essentially (but not exactly) the same instant, with its own internal windowing/smoothing. Production code should treat `Device Utilization %` as authoritative for the *total* and either normalize the per-client shares to sum to it, or accept the small (~1-4%) discrepancy and just clamp the display to 100%.

### Long-running sensor: IOKit object lifetime

This spike calls `IOObjectRelease(accel)` once at the very end, right before the process exits — added for correctness even though the OS would reclaim the send right on exit anyway. **A real sensor must acquire `accel` via `IOServiceGetMatchingService` exactly once at startup and release it exactly once at shutdown** — never re-fetch it per tick (leaks a mach port each time) and never skip the final release in a long-lived daemon/agent process. The per-tick `IORegistryEntryGetChildIterator` iterator (`it`) and each child (`child`) are already released per-iteration via `defer` inside `gpuTimes()` — only the top-level `accel` service handle itself was previously left unreleased.

### Files

- `Spikes/Sources/spike-gpu-apps/main.swift` — the spike + `--load` GPU-load generator.
- Build/run: `cd Spikes && swift build --scratch-path .build-gpu 2>&1 | grep error; swift run --scratch-path .build-gpu spike-gpu-apps --load`.
