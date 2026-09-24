# M0 Findings — Consolidated (Task 9)

Hardware: M1 Max, macOS 26.5. Per-spike detail in `docs/findings/*.md`.

## Summary table

| Source | Status | Cost/sample | Replaces/needs | Findings |
|---|---|---|---|---|
| `proc_pid_rusage` (own-uid CPU/footprint/disk) | done | 2.12 ms (~921 pids) | baseline own-uid metrics; needs responsible-PID grouping, key by pid+start-time (pid reuse) | [procs.md](docs/findings/procs.md) |
| rusage v6 energy (`ri_energy_nj`) | done | included in rusage sweep (same call, V6 flavor) | replaces dead `ri_billed_energy`/`ri_serviced_energy` (confirmed flat under load); needs `RUSAGE_INFO_V6`, not V4 | [procs.md](docs/findings/procs.md) |
| libsysmon | rejected | N/A (rejected in ~1 ms) | fully replaced — coalitions (CPU/energy/disk) + `ps` RSS (memory); AMFI blocks the `com.apple.sysmond.client` entitlement for any non-Apple binary | [sysmon.md](docs/findings/sysmon.md) |
| Resource coalitions | done | ~2.19 ms (list 0.06 + membership 0.43 + usage 1.70) | replaces libsysmon for root/foreign-uid CPU, energy, disk; no memory; `gpu_time` unit unknown — never use it | [sysmon.md](docs/findings/sysmon.md) |
| `/bin/ps` RSS (root/foreign memory) | done (on-demand only) | ~20 ms per call, all pids | only unprivileged source for root-owned memory (RSS, not footprint); not in the steady sampler loop; no privileged helper (decided) | [sysmon.md](docs/findings/sysmon.md) |
| IOReport | done | 1.85 ms avg (179-channel subscription) | CPU/GPU/ANE/DRAM watts + P/E/GPU cluster residency & freq; GPU freq-from-residency not derivable (see gaps) | [ioreport.md](docs/findings/ioreport.md) |
| HID temps (raw list) | partial | 65-78 ms typical (64 services, ~1 ms/service IPC) | raw sensor list only (Thermals detail page), per decision; curated CPU-P/E/GPU split abandoned - SMC covers that instead | [temps.md](docs/findings/temps.md) |
| SMC temps (curated groups) | done | 27-38 ms curated read (80 keys, no enumeration) | replaces HID for curated CPU-P/CPU-E/GPU/SoC/SSD/battery/ambient cards, per decision; confidence varies by group (see gaps) | [temps.md](docs/findings/temps.md) |
| SMC fans | done | negligible (2 extra keys, same SMC session) | only fan source found (`F0Ac`/`F1Ac`, `FNum`=2) | [smc.md](docs/findings/smc.md) |
| Battery | done | not separately benchmarked; SMC float reads us-scale, IOKit registry snapshot untimed | IOKit `AppleSmartBattery` for health/cycles/temp/time-remaining; SMC `PSTR`/`PDTR` needed for live discharge/charge Watts (IOKit has no clean instantaneous-power field) | [smc.md](docs/findings/smc.md) |
| AGX per-app GPU | done | 1.7-2.2 ms (~67-68 clients) | per-app GPU%; needs responsible-PID grouping, non-wrapping counter-reset handling, and identity by pid+creator-name (pid reuse) | [gpu-apps.md](docs/findings/gpu-apps.md) |
| NStat (per-app network) | done | 21-28 ms/query (steady state) | per-app network + live connections; needs the retired-bucket growth bounded before ship (see gaps) | [nstat.md](docs/findings/nstat.md) |
| Disk IOPS | done | 0.17-0.63 ms (6 `IOBlockStorageDriver`s) | system disk I/O rate card | [extras.md](docs/findings/extras.md) |
| NVMe SMART | done | ~0.6 ms lookup + 2-3 ms read = 3-4 ms (targeted); 11 ms full-registry fallback | SSD health card (temp/wear/power-on hours); not a steady-cadence source, refresh every 30-60 s is enough | [extras.md](docs/findings/extras.md) |
| Sleep assertions | done | 0.47-0.85 ms | "why is sleep prevented" transparency, if scoped | [extras.md](docs/findings/extras.md) |
| Router ping | done | gateway lookup 0.06-0.13 ms; 5-ping RTT check ~1.8 s wall-clock (mostly idle wait) | network latency card; run RTT check on its own slow cadence (e.g. every 30 s), not every tick | [extras.md](docs/findings/extras.md) |
| Wi-Fi | partial | ~40 ms cold (first call) / ~3 ms warm | signal/rate/channel card; SSID/BSSID gated behind Location permission - no unprivileged escape hatch found | [extras.md](docs/findings/extras.md) |

Status legend: done = works, recommended; partial = works with a scoped limitation (recorded as a decision below); rejected = not usable, replaced.

## Decisions

Applying the brief's decision rules:

1. **libsysmon rejected, EPERM covers notable root processes** (kernel_task, WindowServer, mds_stores) -> brief says stop and ask. **Already decided by the controller (recorded, not re-decided):** coalitions replace libsysmon for root/foreign CPU, energy, disk; root/foreign memory via `/bin/ps` RSS on demand; no privileged helper. Root-owned process *footprint* stays permanently unavailable (RSS is a proxy) - accepted gap, matches SPEC.md's current "-/estimated" treatment.
2. **IOReport rejected -> GPU% falls back to AGX, ask about dropping Power card**: does not trigger. IOReport works. GPU% has two independent sources — IOReport's `GPUPH` residency % and AGX's per-client `AppUsage` sum / `Device Utilization %` — but **they have not been cross-validated against each other**. The ~1-4 point agreement reported in gpu-apps.md is an AGX-internal check only (the per-client `AppUsage` sum vs. AGX's own `Device Utilization %` key, both read from the same `AGXAccelerator` service); ioreport.md never compares its GPU numbers against AGX. Power card stays, sourced from IOReport's Energy Model channels (idle 2.25 W -> load 8.05 W, plausibility-checked, no `sudo powermetrics` cross-check available in this environment).
3. **HID rejected -> temps from SMC alone**: partially triggers - HID's curated P/E/GPU split failed, but raw enumeration/read succeeded. **Already decided by the controller (recorded):** HID temps = raw list only (Thermals detail page); curated CPU-P/CPU-E/GPU/SoC/SSD/battery/ambient groups come from SMC key families instead.
4. **NStat rejected -> ask user, fallback to system totals only**: does not trigger. NStat works (after 2 review-round-1 fixes: removed-source accounting, thread-safety confirmation). Per-app network + connections proceed as planned. One pre-ship follow-up required (retired-bucket pruning, see Known gaps).
5. **Everything else works -> proceed to M1** (and the later milestones per the roadmap: M2 coalitions/RSS/rusage-v6 energy, M3 IOReport/SMC/HID/battery, M4 NStat).

**Go/no-go: GO.** All 17 sources have a working path into M1-M4, either directly or via an already-decided fallback. No source fully blocks the plan. Root-owned process memory (footprint, not RSS) is the one permanent, accepted capability gap.

## Per-sample cost budget (advisory)

Fix round 1: the first version of this section charged every source's full cost on every tick, which double-counts sources the sampler doesn't actually run that often. Recomputed using the real per-source cadences from `docs/ARCHITECTURE.md` §5.4/§7 — notably NStat runs every **10 s** in the background (not every tick) and SMC uses a cached hard-coded key list (`docs/ARCHITECTURE.md` §7: "< 1 ms, key list from cache"), which is far cheaper than the raw enumeration-free curated-read benchmark in temps.md (see the discrepancy note in Known gaps).

### Background (5 s tick)

| Source | Cost (`docs/ARCHITECTURE.md` §7) | Background cadence | Amortized per 5 s tick | Amortized ms/s |
|---|---|---|---|---|
| sysctl `KERN_PROC_ALL` | < 1 ms | every tick (5 s) | < 1 ms | < 0.2 |
| rusage v6 (~590 pids) | 3–6 ms | every tick | 3–6 ms | 0.6–1.2 |
| coalitions | 1.3–2.1 ms | every tick | 1.3–2.1 ms | 0.26–0.42 |
| IOReport | ~2 ms | every tick | ~2 ms | 0.4 |
| AGX GPU walk | ~2 ms | every tick | ~2 ms | 0.4 |
| SMC (fans + catalog keys + PSTR/PDTR) | < 1 ms | every tick (5 s cadence) | < 1 ms | < 0.2 |
| host/vm/ifaddrs/disk stats | < 1 ms | every tick | < 1 ms | < 0.2 |
| assemble + attribution + alerts + record | 1–3 ms | every tick | 1–3 ms | 0.2–0.6 |
| NStat | 21–28 ms/query | **every 10 s** | (21–28 ms) × 5/10 ≈ 10.5–14 ms | 2.1–2.8 |
| HID raw temps | 65–80 ms | never in background | 0 | 0 |
| `ps` (rootMemory) | ~20 ms, off-queue | 30 s, only with `.processTable`/`.memoryAlert` | ~0 (conditional; excluded from steady baseline) | ~0 |
| **Total per 5 s tick** | | | **≈ 25.6 ms (point est.); range ≈ 24–34 ms** | **≈ 0.51 %; range ≈ 0.48–0.68 %** |

Budget: <1% CPU ⇒ <50 ms/sample at 5 s cadence (hard ceiling per `docs/ARCHITECTURE.md` §7: 25 ms advisory, 50 ms hard). **≈25.6 ms/5 s ≈ 0.51% CPU — inside the advisory budget**, matching `docs/ARCHITECTURE.md` §7's own estimate ("≈ 25–32 ms ≈ 0.5–0.65 % of a core").

### Foreground (1 s, UI open)

Interactive cadences differ per source (`docs/ARCHITECTURE.md` §5.4): NStat runs every tick but off the sampler queue (its own "box queue"); SMC and Wi-Fi run every 2 s; HID raw temps run every 2 s only when the Thermals page requests `.rawTemperatures`.

| Source | Interactive cadence | Amortized ms/s |
|---|---|---|
| sysctl + rusage v6 | every tick (1 s) | ~4.5 |
| coalitions | every tick | ~1.7 |
| IOReport | every tick | ~2 |
| AGX GPU walk | every tick | ~2 |
| host/vm/ifaddrs/disk stats | every tick | < 1 |
| assemble | every tick | ~2 |
| NStat | every tick, box queue | ~21–28 |
| SMC | every 2 s | < 0.5 |
| HID raw temps | every 2 s, Thermals page only | 0 (not in the default UI) |
| Wi-Fi | every 2 s | < 2 |
| **Total** | | **≈ 40–50 ms/s ≈ 4–5 % of a core** |

Matches `docs/ARCHITECTURE.md` §7: "Interactive (1 s) ≈ 40–50 ms/s ≈ 4–5 % while UI is open (advisory)." Both figures are advisory, not gates.

## Known gaps / follow-ups

- **E-core temp mapping confidence: low-medium.** SMC `TC4x`/`TC5x` chosen by elimination (weakest responder to all three load types), not a positive ID.
- **CPU-P temp mapping confidence: medium.** `TC1x` also reacts to E-core-only load (~1/5 as strongly as P-core load) - not a clean split, just P-dominant.
- **GPU MHz not derivable.** IOReport's `GPUPH` residency states (`OFF`, `P1..P15`) don't line up with the `pmgr` `voltage-states9` table (16 states vs. 7) - GPU stays residency-only, no frequency number.
- **SSD HID vs SMC temperature disagreement.** HID `NAND CH0 temp` (39.0 C) vs. SMC `Td0*` avg (55.5 C) ~16.5 C apart at the same instant; `Td0*` also rises under GPU load with zero I/O - `Td` may not be the physical NAND die. HID's SSD reading is kept as production source; `Td` is flagged unresolved, not cross-validated.
- **Media engine channels untested.** IOReport's `AVE0`/`ISP0`/`MSR0`/`DCS0`/`AMCC0` exist and read non-zero at idle but aren't wired to any card or validated under real encode/decode load.
- **ANE load untested.** `ANE0` reads 0.000 W in every run - channel exists and parses, but no no-root trigger was found to confirm it moves under real Neural Engine work.
- **NStat `retired` accumulator is unbounded.** Never pruned; grows one entry per distinct pid ever seen (measured +12 KB RSS/s under synthetic churn). Needs pruning against live pids, or - simpler, and consistent with Task 1's app-grouping precedent - keying retirement by app/responsible-pid instead of raw per-launch pid, before ship.
- **Coalition `gpu_time` unit is unknown.** Confirmed not ns or mach ticks vs. AGX ground truth (ratio ~0.30-0.34x, inconsistent). Do not use it; GPU stays sourced from AGX (per-app) + IOReport (system).
- **Wi-Fi SSID/BSSID require Location permission** (`NSLocationUsageDescription` + entitlement + user consent) - no unprivileged escape hatch exists (verified `SCDynamicStore` is gated the same way, contradicting an earlier draft of extras.md).
- **rusage v6 energy vs. GPU work: untested.** Unclear whether `ri_energy_nj` includes GPU-attributed energy for a process; no GPU load was run in that harness. If a follow-up shows it doesn't, the CPU-cycle-share fallback design in procs.md covers the GPU term.
- **IOReport accuracy vs. `powermetrics`: not directly cross-checked.** No interactive `sudo` available in the spike environment; validated by plausibility (idle/load deltas, per-domain independence) only.
- **Router default-gateway ambiguity under VPN.** A second `RTF_GATEWAY` default route (e.g. from a `utun` VPN) isn't disambiguated - the spike takes the first sysctl match with no metric/interface tie-breaking. Not hit on this machine (Docker's bridge route lacks `RTF_GATEWAY`), but flagged as untested for the VPN case.
- **Temps delta test ran under concurrent load from other spikes**, which likely compressed the P/E/GPU split signal (elevated, smeared baseline). An isolated re-run is recommended before trusting the E-core split further.
- **SMC cost estimate discrepancy.** `docs/ARCHITECTURE.md` §7 estimates the production SMC read (fans + catalog keys + PSTR/PDTR, cached key list) at < 1 ms, but temps.md's own measured curated read (exact `smc_read` calls by name, no enumeration) took 27–38 ms for 80 keys. Either the production curated set is much smaller than the 80 keys temps.md benchmarked, or the < 1 ms estimate needs re-measuring against a real cached-key-list implementation before M3.
