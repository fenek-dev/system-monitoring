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
2. **IOReport rejected -> GPU% falls back to AGX, ask about dropping Power card**: does not trigger. IOReport works. GPU% has two independent, cross-validated sources (IOReport residency + AGX `Device Utilization %`, agreeing within ~1-4 points, see gpu-apps.md). Power card stays, sourced from IOReport's Energy Model channels (idle 2.25 W -> load 8.05 W, plausibility-checked, no `sudo powermetrics` cross-check available in this environment).
3. **HID rejected -> temps from SMC alone**: partially triggers - HID's curated P/E/GPU split failed, but raw enumeration/read succeeded. **Already decided by the controller (recorded):** HID temps = raw list only (Thermals detail page); curated CPU-P/CPU-E/GPU/SoC/SSD/battery/ambient groups come from SMC key families instead.
4. **NStat rejected -> ask user, fallback to system totals only**: does not trigger. NStat works (after 2 review-round-1 fixes: removed-source accounting, thread-safety confirmation). Per-app network + connections proceed as planned. One pre-ship follow-up required (retired-bucket pruning, see Known gaps).
5. **Everything else works -> proceed to M1** (and the later milestones per the roadmap: M2 coalitions/RSS/rusage-v6 energy, M3 IOReport/SMC/HID/battery, M4 NStat).

**Go/no-go: GO.** All 17 sources have a working path into M1-M4, either directly or via an already-decided fallback. No source fully blocks the plan. Root-owned process memory (footprint, not RSS) is the one permanent, accepted capability gap.

## Per-sample cost budget (advisory)

Steady-state per-tick sources (excludes on-demand/slow-cadence items - `ps` RSS, NVMe SMART, ping RTT check, HID raw list - noted separately below):

| Source | ms |
|---|---|
| `proc_pid_rusage` sweep (+ v6 energy) | 2.12 |
| Resource coalitions (list + membership + usage) | 2.19 |
| IOReport | 1.85 |
| AGX per-app GPU walk | 1.97 |
| NStat query | 24.5 |
| Disk IOPS | 0.40 |
| SMC curated temps | 32.5 |
| SMC fans | ~0.1 |
| Battery (SMC + IOKit) | ~1.0 (estimate) |
| Sleep assertions | 0.66 |
| Wi-Fi (warm) | 3.0 |
| **Total** | **approx. 70.3 ms** |

Budget: <1% CPU means <50 ms/sample at 5 s cadence, <10 ms/sample at 1 s cadence.

- **5 s background cadence:** 70.3 ms / 5000 ms = approx. **1.41% CPU** - ~20 ms over the advisory budget.
- **1 s foreground cadence:** 70.3 ms / 1000 ms = approx. **7.03% CPU** - well over the advisory budget.

Dominated by NStat (24.5 ms, 35%) and SMC curated temps (32.5 ms, 46%) - together 81% of the total. The core CPU/memory/GPU path (rusage + coalitions + IOReport + AGX) is only ~8.1 ms, comfortably inside even the 1 s budget on its own. This matches each spike's own cadence recommendation: temps.md recommends a 2 s cadence, nstat.md says 1-2 s is fine - neither was designed for a 1 s tick. **Recommendation (advisory, not a gate):** run CPU/memory/GPU/energy/disk at the foreground 1 s cadence; run temps and network on their own 2 s (or slower) cadence regardless of foreground/background state.

If HID's raw full read (65-78 ms) is also polled every tick (e.g. Thermals page open), add ~70 ms giving a total of approx. 140.3 ms (2.81% at 5 s, 14.0% at 1 s) - another reason to keep it on-demand rather than in the default loop.

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
