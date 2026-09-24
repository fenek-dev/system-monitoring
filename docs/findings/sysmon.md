# M0 Findings (M1 Max, macOS 26.5)

## sysmon — libsysmon / sysmond, plus alternatives for root-owned processes

**Verdict:** libsysmon does not work for us. Resource coalitions do.
- **CPU time for root-owned processes without root: YES**, through `coalition_info_resource_usage`. It also gives energy (nJ), disk read/write bytes and wakeups. It gives GPU time too, but in an unknown unit. The data is per coalition, and a coalition contains one or more responsible-pid apps.
- **Memory (footprint/RSS) for root-owned processes without root: NO** through any in-process API. The fallbacks are spawning the setuid-root `/bin/ps` (RSS only, about 20 ms) or a privileged helper.

Spike: `swift run --scratch-path .build-sysmon spike-sysmon` (in `Spikes/`).

### A. libsysmon / sysmond: outcome (b), rejected ❌
- sysmond rejects every client that lacks the `com.apple.sysmond.client` entitlement. sysmond log (`/usr/bin/log show --info --debug --predicate 'process == "sysmond"'`, run as the full path because zsh has a `log` builtin):
  - `Client 75186 denied; missing "com.apple.sysmond.client" entitlement.`
  - `(libxpc.dylib) Peer connection was rejected by the listener (xpc_connection_cancel())`
- In the client, `sysmon_request_create_with_error` reports `Disconnected by sysmond server, likely due to bad entitlements` for types 1, 2 and 3, within about 1 ms.
- The plain `sysmon_request_create` handler gets an **empty table** (count 0) on rejection, not NULL. A rejection therefore looks exactly like "no rows". Always use `_with_error`.
- **Ad-hoc signing with the entitlement:** see `Spikes/sysmon.entitlements`. The process is SIGKILLed at exec (exit 137). Kernel log, verbatim (`gtimeout` is the `timeout` wrapper that exec'd the binary):
  ```
  2026-09-24 15:11:26.560 Df kernel[0:1224aea] proc 75647: load code signature error 4 for file "spike-sysmon-ent"
  2026-09-24 15:11:26.561 Df kernel[0:1224aea] (AppleMobileFileIntegrity) AMFI: hook..execve() killing gtimeout (pid 75647): Attempt to execute completely unsigned code (must be at least ad-hoc signed).
  2026-09-24 15:11:26.561 Df kernel[0:1224aeb] (AppleSystemPolicy) ASP: Security policy would not allow process: 75647, /Users/arturvorokov/Documents/Projects/system-monitor/.claude/worktrees/agent-a6dcaa37081b10eaf/Spikes/.build-sysmon/spike-sysmon-ent
  ```
  Control: the same binary, ad-hoc signed without the entitlement, runs normally. So AMFI treats `com.apple.sysmond.client` as a restricted entitlement. A Developer ID build cannot get it either, because Apple does not provision `com.apple.*` private entitlements. It could only work with AMFI or SIP disabled, which is not viable for a product.
- The entitlement is held by Activity Monitor (`codesign -d --entitlements -`). `top` and `ps` are setuid root instead.
- Reverse-engineered facts from the disassembly (in `Sysmon.h`):
  - Request type must be 1–3. `sysmon_request_add_attribute` runs `brk #1` (SIGTRAP, exit 133) for type 0 or ≥4. The brief's loop over types 1…4 crashed on type 4.
  - The attribute bitmap is 10, 5 or 2 bytes for types 1, 2 and 3, so attribute IDs are < 80, < 40 and < 16. Larger IDs are logged and ignored.
  - `sysmon_request_create_with_error(type, ^(sysmon_table_t table, const char *error))`. The error block sits at a different slot and gets `(table, errstr)`. On error, table is NULL.
  - Mach service `com.apple.sysmond`. Request dict = `{type: u64, attrs bitmap: data, [interval]}`.
- Attribute IDs (pid, name, cpu, footprint, …): **unknown**. They could not be mapped because no rows ever come back.

### B. Per-pid kernel APIs, unprivileged (953 pids, 330 not owned by my uid)
| API | not-my-uid ok | notes |
|---|---|---|
| `proc_pid_rusage` | 0/330 (EPERM) | baseline from procs.md |
| `proc_pidinfo(PROC_PIDTASKINFO)` | 0/330 (EPERM) | **same gate as rusage**, no help |
| `proc_pidinfo(PROC_PIDTBSDINFO)` | 0/330 (EPERM) | this is why `proc_name()` fails for root pids |
| `proc_pidinfo(PROC_PIDT_SHORTBSDINFO)` | **330/330** | name (16 chars), uid, ppid, status |
| `proc_pidpath` | **329/330** | full executable path; fails only for kernel_task (ESRCH) |
| `proc_pidinfo(PROC_PIDCOALITIONINFO=20)` | **330/330** | resource and jetsam coalition IDs |
| `task_name_for_pid` + `TASK_VM_INFO` | 0/330 | `KERN_FAILURE` (5) at task_name_for_pid |
| `sysctl KERN_PROC_ALL` | names for all 953 | `p_uticks/p_sticks/p_rtime/p_pctcpu` are **zero for all but 2/953**. No CPU data |
| `memorystatus_control` (priority list / on-demand jetsam snapshot) | EPERM | root-only |
| `footprint -p 418` (CLI) | fails | `Unable to find any processes matching the supplied process names or pids (try as root?)` |
| `vmmap 418` (CLI) | fails | `cannot examine process 418 (WindowServer) because you do not have appropriate privileges to examine it` |

Other `proc_pid_rusage` flavors (V0 to V6) go through the same xnu same-uid gate, so they fail the same way. `ledger()` is untested.

We can **name** every process, root or not, via `SHORTBSDINFO`, `proc_pidpath` or sysctl `p_comm`. procs.md's `"pid N"` fallback is not necessary. We **cannot** get per-pid CPU or memory for foreign-uid processes.

### C. Resource coalitions: CPU, energy, disk, GPU for root processes ✅
- `proc_listcoalitions(LISTCOALITIONS_ALL_COALS, 0, buf, size)` lists about 784 resource and 714 jetsam coalitions, unprivileged. Entries are `{u64 id; u32 type; u32 tasks}`.
- `coalition_info_resource_usage(cid, buf, size)` succeeded for 783/784 resource coalitions, unprivileged. One returned EINVAL, probably a coalition that died between list and query.
- **Sweep cost**, cheap enough for 1 Hz:
  - `proc_listcoalitions`: 0.06 ms for 1471 coalitions.
  - `PROC_PIDCOALITIONINFO` over all pids: 0.35–0.51 ms for 927–933 pids.
  - `coalition_info_resource_usage` over all resource coalitions: 1.3–2.1 ms for about 769.
  - The reviewer measured the same ranges independently. The kernel copies **360 bytes (45 × u64)** on 26.5, measured with a sentinel fill. Stable prefix, declared in `Coalition.h`:
  `[0] tasks_started [1] tasks_exited [2] time_nonempty [3] cpu_time (mach ticks) [4] interrupt_wakeups [5] platform_idle_wakeups [6] bytesread [7] byteswritten [8] gpu_time [9] cpu_time_billed_to_me [10] cpu_time_billed_to_others [11] energy (nJ)`.
- Membership map pid → coalition via `PROC_PIDCOALITIONINFO`, which is unprivileged.
- **Accuracy vs ground truth.** Ground truth is setuid `ps` and `top`. Cumulative CPU converted with mach timebase 125/3:

  | process | coalition cpu_time | ps/top TIME | Δ |
  |---|---|---|---|
  | WindowServer (+MTLCompilerService) | 573,096 s | 580,089 s (9668:09) | −1.2% |
  | mds_stores (pid 534, sole member) | 11,857 s | 11,996 s (199:56) | −1.2% |
  | coalition 1 = kernel_task + launchd | 275,160 s | 265,186 + 12,414 = 277,600 s | −0.9% |

  2-second delta CPU%: WindowServer 56.7% vs `top` 58.8%. Coalition 1 32.9% vs `top` kernel_task 31.3% + launchd 0.1%. Cumulative values are consistently about 1% lower than `ps`. The cause is unknown. It is negligible for the UI.
  - **Billed-time words do not explain the under-read.** For WindowServer, `ps` minus coalition = 7,004 s. `[9] billed_to_me` is 14,057 s and `[10] billed_to_others` is 51,458 s; subtracting `[10]` makes the gap worse. For mds_stores the gap is 141 s and `[9]` is 148 s, a near-match, but it does not generalize: coalition 1 has `[9]` = 0 and still reads 0.9% low. Do not correct cumulative time with `[9]` or `[10]`. Use deltas of `[3]`.
- **Granularity for the 330 foreign pids:** 255 are the sole live member of their coalition, so CPU is exact per process. The cumulative figure includes exited tasks of the same job. 1 shares only with my own pids, so subtract my rusage. 74 share with other foreign pids, for example coalition 1 = kernel_task + launchd, and WindowServer + MTLCompilerService. That gives 282 distinct coalitions.
- **Coalition vs responsible-PID ("app") grouping: coalition ⊇ responsible group, not equal.** The reviewer measured this and I re-verified it:
  - 595/595 pids that have a responsible pid are in the same coalition as it. A coalition never splits a responsible group.
  - But 5 coalitions hold more than one responsible root, covering 128 pids. Examples:
    - coalition 98647 = Claude.app 55507 + several separately responsible `node`/`uv`/`claude` CLI roots (58909, 56241, …);
    - coalition 81829 = 9 separately responsible `postgres` roots;
    - coalition 95556 = `node`/`esbuild`/`api` roots.
  - The reviewer counted 97/595 pids sharing a coalition with a different responsible root, on a different process set.
  - `responsibility_get_pid_responsible_for_pid` returns nothing for all 331 foreign-uid pids.
  - **Rule:**
    - For own-uid pids, use responsible-pid grouping with `proc_pid_rusage`.
    - For foreign-uid pids, use coalitions, since that is the only source.
    - Also use coalitions for per-app energy attribution.
    - Never use a coalition as the app key for own-uid processes.
- **No memory.** Words 12–44 of the WindowServer coalition contain nothing near `top` MEM (809 MB) or its page count. The coalition struct carries no footprint.
- **`energy` [11] is in nJ, and it rises under CPU load.**
  - This spike, busy thread in our own process for 2 s: our coalition's energy Δ ≈ 3.43 W, and our pid's rusage v6 `ri_energy_nj` Δ = 5.2e9 nJ ≈ 2.6 W. Stable across 4 runs, 2.59–2.62 W.
  - Reviewer, running `yes` for 5 s in our coalition: energy Δ 26.7e9 vs 13.7e9 baseline, ≈ +2.6 W. `yes` has `ri_billed_energy` = 0, but rusage v6 `ri_energy_nj` = `ri_penergy_nj` = 16.7e9 (3.3 W).
  - Both sources are in nJ:
    - per pid, own uid only: rusage v6 `ri_energy_nj`; `ri_penergy_nj` is the P-core share. Not `ri_billed_energy`.
    - per coalition, any uid: `[11]`.
  - WindowServer at about 50% CPU shows only about 0.12 W of coalition energy. Its CPU runs mostly on E-cores, and its GPU energy is probably not counted here.
- **`gpu_time` [8]: unit unknown. Do not use it.**
  - Over the same 2 s, WindowServer's coalition `gpu_time` Δ ≈ 0.30–0.34 × the AGX `accumulatedGPUTime` Δ (ns, pid 418, all `AppUsage` entries summed), in 4 runs.
  - That ratio is neither 1 (ns) nor 1/41.67 (mach ticks). The AGX sum may double-count overlapping channels, or the coalition may count a subset.
  - Use AGX per-pid ns (gpu-apps.md) for GPU instead.

### Memory for root processes: options
1. `posix_spawn("/bin/ps", "-Axo pid=,rss=")`. `ps` is setuid root. Covers all pids, RSS only (not footprint), about 20 ms per call. Hacky. Not usable from an App Sandbox.
2. `top -l 1 -stats pid,mem` gives footprint (MEM) but takes about 780 ms per sample. Too slow for 1 Hz.
3. A privileged helper (SMAppService LaunchDaemon, root) that runs `proc_pid_rusage` for all pids and serves results over XPC. This is the correct way to get footprint, and also exact per-process CPU for all 330. It costs a one-time admin approval.
4. Show "—" for the memory of foreign-uid processes, and show CPU, energy and disk from coalitions.

### Decision
- **Can we get CPU time for root-owned processes without root? Yes.** Coalition `cpu_time`, within about 1% of `ps` (see table in C). Energy (nJ) and disk bytes come with it. GPU time also comes with it, but its unit is unknown, so do not use it.
- Coalitions are the source for foreign-uid processes and for per-app energy only. The app key stays the responsible pid, because a coalition can hold several apps.
- **Can we get memory for root-owned processes without root? No,** except by spawning setuid `ps` for RSS. Footprint needs a privileged helper.
- Drop libsysmon from the plan. It is gated by a restricted entitlement that AMFI enforces.
