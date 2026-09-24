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

### Files

- `Spikes/Sources/spike-gpu-apps/main.swift` — the spike + `--load` GPU-load generator.
- Build/run: `cd Spikes && swift build --scratch-path .build-gpu 2>&1 | grep error; swift run --scratch-path .build-gpu spike-gpu-apps --load`.
