# Rulings made during the build (2026-09-24/25)

These are decisions the build orchestrator made on its own during the parallel build, without asking the user — reviewed here for approval, not yet re-litigated.

## Attribution & engine

- **`ProcessSample.coalitionLeaderName: String?` added (ICR-4)** — why: design's app tooltip needs a coalition leader name — cost if wrong: one extra optional field, no behavior change.
- **`AlertConfig`/`EpisodeConfig` live in `MonitorEngine/Alerts/AlertConfig.swift`, owned by stream W1** — why: engine-only types, avoids duplicate ownership — cost if wrong: none.
- **`AppMetric.energy` sources include processes and coalitions; `MetricVector` ±0 equality accepted as a known deviation** — why: interface gaps found in the W0a review — cost if wrong: trivial, a cosmetic equality edge case.
- **Grouping rule 3 changed: every bundle-less process (any uid) gets its own group by executable name; `.system` only when there's no path and no name; a responsible-path EPERM falls back to its `p_comm`; no child-path fallback.** Supersedes the original ARCH §5.1 grouping rule — why: DESIGN §3.12 wins — cost if wrong: many daemon rows appear in Apps mode (the UI's top-N view absorbs it).
- **ICR-5: `EnergyAttributor` exposes `estimatedIDs: Set<ProcessID>`; `FrameAssembler` sets `AppSample.energyEstimated` from it** — why: arch gap, no way to flag estimated rows — cost if wrong: one extra property.
- **Single-fill residual rule kept: a restricted pid absorbs the CPU/energy residual, including leakage from exited children** — why: allowed by the binding rule; flagged to revisit if seen in real data — cost if wrong: occasional misattribution to the restricted row.
- **ICR-7: `.processTable` sampling demand limited to Overview/Memory/Processes pages plus the inspected app** — why: `ps` was running on every dashboard page regardless of need — cost if wrong: none, other pages don't show a memory column anyway.
- **ICR-8: per-app watts = v6 CPU energy (or coalition-residual/SoC-CPU-share) + IOReport GPU watts × the app's AGX GPU share; row marked `energyEstimated` when the GPU term exceeds 10% of the row total** — why: measured gap for GPU-heavy apps under CPU-only energy — cost if wrong: the GPU term is inherently an estimate.
- **Alert thresholds trigger on `≥`, not `>`** — why: tests already lock this behavior; SPEC's `>` was approximate — cost if wrong: none.
- **Alert timers use monotonic uptime; trackers reset on a gap > 2× nominal cadence or after wake; ARCH §5.8's `Date` param is kept only for event timestamps** — why: clock jumps (sleep/wake, NTP) must not fire false alerts — cost if wrong: small API surface addition.
- **App CPU-spike episodes classified at severity `.elevated`** — why: matches other episode severities — cost if wrong: none, cosmetic.
- **Network aggregator uses the primary interface for net totals; disk aggregator excludes DMG drivers from disk totals** — why: avoids double-counting virtual interfaces/mounted images — cost if wrong: none.
- **ICR-10: `NavigationModel.inspectedApp` / `VisibilityInputs.inspectedApp` added, set by ProcessesPage only while the detail row is expanded** — why: connection-sampling demand needs to know which app is inspected — cost if wrong: small API addition.
- **ICR-11: `isDiskImage` model field approved** — why: needed to identify DMG-backed volumes for the disk-totals exclusion — cost if wrong: none.
- **ICR-12: `memPressureLevel` added; rollups store the average; consumer thresholds set at 2.5 and 1.0** — why: needed for pressure display/alerts — cost if wrong: thresholds are a judgment call, may need tuning.
- **ICR-13: a synthetic "exited processes" row appears when the all-visible coalition residual exceeds 5% of core or a 10% delta** — why: otherwise CPU/energy silently vanishes when a process exits mid-tick — cost if wrong: the row appears more or less often than ideal.
- **ICR-14: `ProcessSample`/`AppSample` get `diskRead/WriteSession` fields, baselined engine-side** — why: DESIGN §3.11 needs exact "since start" semantics only the engine can provide — cost if wrong: two optional fields plus a small accumulator.
- **App disk-session totals accumulate via `SessionAccumulator` and survive an engine reset (session start = the process's exact `p_starttime`); CPU/net session totals still drop the gap across a reset, documented as such** — why: ICR-14's "since start" semantics for disk; CPU/net can't be reconstructed across a gap — cost if wrong: CPU/net undercount across a long pause or sleep.
- **`SessionAccumulator` prunes app keys unseen for more than 24h; a returning app's session total restarts at 0** — why: unbounded growth otherwise — cost if wrong: a relaunched app's totals reset instead of resuming.
- **Per-app GPU % = app GPU time × 100 / max(100, Σ clients), same pattern as the ICR-8 energy split.** Supersedes the earlier "normalize by Σ clients" wording from the IOReport GPU ruling — why: needed a precise formula — cost if wrong: per-app percentages can sum to more than the system GPU total.

## Sensors

- **`SensorCadence.init` defaults its background cadence to nil; `IconArc` gets `CodingKeyRepresentable`; Int32-keyed dicts stay array-encoded** — why: Codable gaps found in the W0a interface review — cost if wrong: trivial, encode/decode only.
- **E-core temperature group (TC4x/5x sensors) kept, with an "approximate mapping" caption shown only on that group** — why: no better SMC key exists to identify E-core temps — cost if wrong: E-core temp readings may be inaccurate.
- **`fpe2` divided by 4 kept as-is; GPU MHz table is a hard-coded pmgr table** — why: validated against a known machine (P6) — cost if wrong: GPU clock readout wrong on unlisted hardware.
- **Wi-Fi sensor requires `.wifi` reachability plus an off-queue read; latency pings the physical primary router; VPN-only connections show unavailable** — why: avoids blocking the sampler and misleading VPN latency — cost if wrong: none, fails safe to unavailable.
- **Free space = available capacity (statfs `available` / container free, matches `diskutil`) used everywhere; purgeable space kept as a separate "· N GB purgeable" sub-line** — why: one consistent definition, matches the reference design's free-space ruling — cost if wrong: minor copy deviation from the reference design.
- **GPU media card shows a single "Media engine" row, hidden if absent** — why: IOReport only exposes a combined encode/scale channel — cost if wrong: none.
- **Battery: watts = signed V×InstantAmperage (negative discharging, positive charging); health clamps at ≤100%; "calculating" is a distinct state; adapter shown as "{W} W USB-C"; unknown thermal state maps to "serious"** — why: matches what the hardware actually reports — cost if wrong: minor display inaccuracy on edge-case hardware.
- **`VolumeSensor` filters to local volumes via `getfsstat(MNT_NOWAIT)` + `MNT_LOCAL` before any capacity call** — why: Disk page only shows local volumes; avoids blocking on a dead network share — cost if wrong: none, network volumes just don't appear.
- **IOReport re-baselines on any gap greater than 15s, not just sleep/wake** — why: avoids overstating SoC power off a stale baseline — cost if wrong: none.
- **System GPU % is read from IOReport's GPUPH residency counter; AGX `deviceUtilization` used only as a fallback when IOReport is unavailable** — why: any other reader of AGX's utilization counter resets it — cost if wrong: none.

## Storage & history

- **Store maintenance (rollups/pruning) runs on its own timer (5 min + at open), never inside the append/flush path** — why: the sampling loop must never block on maintenance — cost if wrong: rollups can lag up to 5 min (the raw tail covers the gap).
- **Store busy-write timeout is 1.5s; shutdown flush must finish inside its own budget, and a busy write at shutdown is attempted once, not retried** — why: shutdown must not hang on a locked DB — cost if wrong: a rare BUSY error under contention (normally logged and retried on the next flush; dropped if it happens at shutdown).
- **R-I2: the history DB must stay under 200MB even with the dashboard open all day — keep only threshold-passing apps plus "other" in the 1-min/15-min rollups, and prune the oldest raw data early (never inside the last hour) if the file exceeds 180MB** — why: final review projected ~276MB with the dashboard open all day — cost if wrong: old raw history disappears sooner than expected.
- **R-I3: the in-memory fallback (no DB) keeps short retention — raw for 1h, 1-min rollups for 24h, 15-min rollups for 7d, target under 10MB, with a guard that trims raw to the last 15 min if exceeded** — why: an unbounded in-memory fallback was found in final review — cost if wrong: history is lossy while running without a persistent store.
- **A crash/kill-9 leaves an open event (end = NULL); on next store open it's closed using the timestamp of the last record at or after its start** — why: otherwise an orphaned event looks like it's still running forever — cost if wrong: the closed timestamp is an approximation, not the true end.
- **Kept-batch cap: drop write-queue entries older than 600s, and log it** — why: an unbounded queue during sustained DB contention — cost if wrong: the oldest queued samples during a stall are dropped instead of retried.
- **A store-open failure shows a banner over the in-memory data rather than blocking the UI** — why: ARCH §6 wants the app usable even if the DB can't open — cost if wrong: page-state handling gets more complex.

## App shell & actions

- **A-I3: Quit on an app group asks only the app to quit (`NSRunningApplication.terminate` for bundled apps; SIGTERM to the group leader only for bundle-less groups); Force Quit kills every member pid, each start-time-verified. DESIGN §2.25 updated.** — why: distinguishes a graceful quit from a forced one for multi-process apps — cost if wrong: Quit could leave helpers running, or Force Quit could kill more than intended.
- **A second launch activates the already-running instance (distributed notification or `NSRunningApplication` activate) and exits, scoped per data dir** — why: prevents two instances writing the same store; per-data-dir scoping lets dev worktrees run alongside a production instance — cost if wrong: two instances could contend for one DB file.
- **Confirm dialogs (Power/Disk/Thermals) go through one window-level `\.presentConfirmDialog` host, not a page-level dialog** — why: DESIGN's full-window dialog pattern — cost if wrong: inconsistent dialog behavior per page, duplicate dialog code.
- **Dev/test data dirs never placed under `~/Documents`; `scripts/run.sh` uses `~/Library/Caches/dev.telltale-dev/<worktree-name>`; production default is `~/Library/Application Support/dev.telltale`** — why: the repo lives under `~/Documents`, which triggers a macOS TCC permission prompt — cost if wrong: none, purely a path choice.
- **The `[Sample]` button (Processes/Power) kept per DESIGN §6.23 — samples the current process tree for 3s, own-user only** — why: design explicitly calls for it — cost if wrong: spawns a short-lived helper process and a temp file per use.
- **Sample stays a separate `ProcessSampling` service rather than folding into `ProcessActions`** — why: keeps sampling isolated from action/signal code — cost if wrong: two injection points instead of one.
- **New `ActionResult` states `requested`/`exited` added; a target with an unknown start time is treated as already exited and never signalled** — why: avoids signalling the wrong process after a pid gets reused — cost if wrong: a legitimate action could be silently refused.
- **A bundle-less process group's "leader" (target for group actions) is its earliest-started member** — why: bundle-less groups have no natural leader like an app bundle does — cost if wrong: group Quit/Force Quit could target the wrong pid.
- **`LiveModel` always applies `sensorHealth` via `healthVersion`, even when Settings isn't presenting** — why: Settings showed sensors as empty when the page wasn't visible — cost if wrong: none, strictly a bug fix.

## UI & design deviations

- **Timeline card height fixed at 276pt; font-smoothing issue investigated inside the renderer, design tokens left unchanged** — why: matching the reference layout — cost if wrong: none.
- **`AppleFontSmoothing=0` accepted as a process-wide launch argument** — why: matches the design's intended antialiased text rendering — cost if wrong: affects text rendering process-wide, not just Telltale's own views.
- **Remaining visual diffs against the reference are already covered by existing SPEC rulings (dropped Renderer/GPU-mem/App-Nap rows, energy in watts, 30D+Live range, pressure colors without bands) — no further action taken.**
- **Popover row: a single tap acts immediately; double-click restores the previous state instead of waiting 0.5s** — why: responsiveness — cost if wrong: a brief visible flicker on double-click.
- **7D/30D range chips and the "At" label show weekday + HH:mm** — why: bare timestamps were ambiguous across ranges — cost if wrong: a copy change if it reads poorly.
- **The 30-day window snaps to the store's epoch 2h bucket grid, which may start up to 1h before local midnight** — why: avoids showing "—" at "now" from timezone misalignment — cost if wrong: the first day's axis label can be off by up to 1h.
- **A floating toast pill is used on pages that have no toolbar spacer** — why: DESIGN §3.12 only defines toast placement for the Processes page — cost if wrong: visual placement varies page to page.
- **Thermals temperature axis floor = min(40°, floor(min sample) − 5), rounded to 10** — why: a real 31°C battery reading must not be clamped off the chart — cost if wrong: axis position varies by device state.
- **DESIGN DEVIATION: the Thermals temp axis can extend below the reference's fixed 40° floor when battery reads ~31°C** — why: chose truthfulness over pixel-for-pixel match — cost: visible deviation from the reference design in that state.
- **Long process names ("trustd"-style rows) can lose their last ~2pt of width under the fixed 72pt name-column rule** — why: accepted as a minor, rare rendering artifact — cost if wrong: name reads as very slightly clipped in narrow cases.
- **The "Live" badge shows only when a range is pinned to Live** — why: DESIGN §3.13's pinned-range semantics — cost if wrong: a copy/label change.
- **A custom scrubber control is built if `NSSlider` renders grey in the key window instead of tinted** — why: pixel fidelity to the reference — cost if wrong: extra accessibility work to match native slider behavior.
- **The coalition PID column shows "—" for synthetic rows and group rows** — why: those rows have no single real pid — cost if wrong: none.

## Process & tooling

- **All parallel build streams run in isolated git worktrees (plan §0)** — why: user explicitly asked for max parallelism — cost if wrong: merge fixups when streams collide.
- **Stream W0a starts concurrently with the ARCH rev3 scoped re-review; any Model-level review fixes fold straight into W0a** — why: avoids a serial review gate blocking every other stream — cost if wrong: small rework if the re-review changes shared Model types.
- **Streams W0b, W1, W2, W6a start on top of W0a's branch before it's merged or reviewed** — why: max parallelism — cost if wrong: rebase fixups if W0a's review changes shared Model code.
- **Stream tasks reviewed in batched groups of 2–4, except load-bearing interfaces (e.g. W1's core sampling type), which get their own review** — why: saves reviewer turnaround — cost if wrong: a later-found issue can span more commits to fix.
- **Streams W5a/b/c start on top of W3/W4/Wm's unreviewed branches** — why: max parallelism — cost if wrong: rebase on review fixes from those streams.
- **Stream W7 authorized to edit W1's files directly for 3 minor fixes (W1 already finished); fixture trim-idle behavior approved** — why: avoids routing trivial fixes back through a finished stream — cost if wrong: none, owner reviewed the diff scope.
- **Hardware-touching smoke tests are opt-in via `TELLTALE_HW_TESTS` and serialized at checkpoints** — why: parallel agents share one physical test machine — cost if wrong: HW checks excluded from the default CI run.
- **`FixtureCoding.swift` made public in `MonitorEngine/Fixtures`** — why: stream W7 needed it for fixture replay — cost if wrong: none, a visibility change only.
- **`ci.sh` sets `TT_SNAPSHOT_STRICT=1`: a missing golden image fails the gate instead of silently passing** — why: catches accidentally-unrecorded goldens — cost if wrong: local runs need an explicit record step first.
- **Stream C (sensors) authorized to edit `SensorSlot`/`CrashCanary` in the engine layer for canary work** — why: canary arm/disarm logic spans the sensors/engine boundary — cost if wrong: minor scope overlap between streams, both reported it.

## Deferred (not done)

- **Sleep-wake fixture recording and the 8-hour soak test** — need the user to run manually (`scripts/probe.sh --record .../sleep-wake.json --ticks 20 --interval 1 --mode interactive --trim-idle`, with a real sleep ≥15s mid-recording).
- **Overview page perf A/B (with vs without the hotspot fixes)** — inconclusive: 4.76% vs 5.40% CPU, machine was noisy.
- **`assemble920` benchmark** — last measured at 3.7ms on a noisy machine; needs re-measuring on an idle one.
- **U-M10: duplicated range-reader/grid-row helper code** across History pages, never consolidated.
- **N5: hover-only row actions don't work with Voice Control** (or any non-hover input) — accessibility gap.
- **N6: a sensor re-prepare (restart) can run without the crash canary armed.**
- **Mock CSV export format differs from the real exporter's** (MonitorMocks stub only, not wired to match).
- **M6: the "No data yet" empty-state region only appears on area charts**, not other chart types.
- **The `[Sample]` button reveals its output in Finder; DESIGN says it should open in Console.**
- **`telltale-probe --maintain-now` closes any currently-live app episodes** — acceptable since it's a dev tool, but not fixed.
- **UI-closed idle CPU measured at 1.09%, vs the 1% budget** — advisory, not gated on.
- **`Database.swift:48`'s readonly guard is misleadingly worded; no test covers the write-failure drop path.**
- **`sessionSeenNet` rebuilds from scratch every tick** instead of incrementally — perf minor.
- **A pruned time span leaves a visible gap until the next maintenance run.**
- **An orphaned event older than the raw-retention window collapses to zero length** instead of showing its real duration.
- **Worst-case shutdown takes ~3.7s, bounded only by the runtime's own timeout** — not a hard budget.
