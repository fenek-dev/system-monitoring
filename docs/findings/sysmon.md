# M0 Findings (M1 Max, macOS 26.5)

## sysmon — libsysmon / sysmond, plus alternatives for root-owned processes

**Verdict:** libsysmon does not work for us. Resource coalitions do.
- **CPU time for root-owned processes without root: YES**, through `coalition_info_resource_usage`. It also gives energy, disk read/write bytes, GPU time and wakeups.
- **Memory (footprint/RSS) for root-owned processes without root: NO** through any in-process API. The fallbacks are spawning the setuid-root `/bin/ps` (RSS only, about 20 ms) or a privileged helper.

Spike: `swift run --scratch-path .build-sysmon spike-sysmon` (in `Spikes/`).

### A. libsysmon / sysmond: outcome (b), rejected ❌
- sysmond rejects every client that lacks the `com.apple.sysmond.client` entitlement. sysmond log (`/usr/bin/log show --info --debug --predicate 'process == "sysmond"'`, run as the full path because zsh has a `log` builtin):
  - `Client 75186 denied; missing "com.apple.sysmond.client" entitlement.`
  - `(libxpc.dylib) Peer connection was rejected by the listener (xpc_connection_cancel())`
- In the client, `sysmon_request_create_with_error` reports `Disconnected by sysmond server, likely due to bad entitlements` for types 1, 2 and 3, within about 1 ms.
- The plain `sysmon_request_create` handler gets an **empty table** (count 0) on rejection, not NULL. A rejection therefore looks exactly like "no rows". Always use `_with_error`.
- **Ad-hoc signing with the entitlement:** see `Spikes/sysmon.entitlements`. The process is SIGKILLed at exec (exit 137). The kernel logs `load code signature error 4` and `AMFI: ... killing ... Attempt to execute completely unsigned code`. Control: the same binary, ad-hoc signed without the entitlement, runs normally. So AMFI treats `com.apple.sysmond.client` as a restricted entitlement. A Developer ID build cannot get it either, because Apple does not provision `com.apple.*` private entitlements. It could only work with AMFI or SIP disabled, which is not viable for a product.
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

We can **name** every process, root or not, via `SHORTBSDINFO`, `proc_pidpath` or sysctl `p_comm`. procs.md's `"pid N"` fallback is not necessary. We **cannot** get per-pid CPU or memory for foreign-uid processes.

### C. Resource coalitions: CPU, energy, disk, GPU for root processes ✅
- `proc_listcoalitions(LISTCOALITIONS_ALL_COALS, 0, buf, size)` lists about 784 resource and 714 jetsam coalitions, unprivileged. Entries are `{u64 id; u32 type; u32 tasks}`.
- `coalition_info_resource_usage(cid, buf, size)` succeeded for 783/784 resource coalitions, unprivileged. One returned EINVAL, probably a coalition that died between list and query. The kernel copies **360 bytes (45 × u64)** on 26.5, measured with a sentinel fill. Stable prefix, declared in `Coalition.h`:
  `[0] tasks_started [1] tasks_exited [2] time_nonempty [3] cpu_time (mach ticks) [4] interrupt_wakeups [5] platform_idle_wakeups [6] bytesread [7] byteswritten [8] gpu_time [9] cpu_time_billed_to_me [10] cpu_time_billed_to_others [11] energy (nJ)`.
- Membership map pid → coalition via `PROC_PIDCOALITIONINFO`, which is unprivileged.
- **Accuracy vs ground truth.** Ground truth is setuid `ps` and `top`. Cumulative CPU converted with mach timebase 125/3:

  | process | coalition cpu_time | ps/top TIME | Δ |
  |---|---|---|---|
  | WindowServer (+MTLCompilerService) | 573,096 s | 580,089 s (9668:09) | −1.2% |
  | mds_stores (pid 534, sole member) | 11,857 s | 11,996 s (199:56) | −1.2% |
  | coalition 1 = kernel_task + launchd | 275,160 s | 265,186 + 12,414 = 277,600 s | −0.9% |

  2-second delta CPU%: WindowServer 56.7% vs `top` 58.8%. Coalition 1 32.9% vs `top` kernel_task 31.3% + launchd 0.1%. Values are consistently about 1% lower than `ps`. The cause is unknown. It is negligible for the UI.
- **Granularity for the 330 foreign pids:** 255 are the sole live member of their coalition, so CPU is exact per process (cumulative includes exited tasks of the same job). 1 shares only with my own pids, so subtract my rusage. 74 share with other foreign pids, for example coalition 1 = kernel_task + launchd, and WindowServer + MTLCompilerService. That gives 282 distinct coalitions. Coalitions are per launchd job, which matches the product's "app" grouping anyway. We can show per-job CPU for kernel_task+launchd, or subtract nothing and label it "kernel & launchd".
- **No memory.** Words 12–44 of the WindowServer coalition contain nothing near `top` MEM (809 MB) or its page count. The coalition struct carries no footprint.
- Units: `energy` is presumably nJ. WindowServer 4.7e14 over about 16 days of uptime ≈ 0.34 W average, which is plausible. Not independently verified yet; cross-check with the IOReport or energy spike.

### Memory for root processes: options
1. `posix_spawn("/bin/ps", "-Axo pid=,rss=")`. `ps` is setuid root. Covers all pids, RSS only (not footprint), about 20 ms per call. Hacky. Not usable from an App Sandbox.
2. `top -l 1 -stats pid,mem` gives footprint (MEM) but takes about 780 ms per sample. Too slow for 1 Hz.
3. A privileged helper (SMAppService LaunchDaemon, root) that runs `proc_pid_rusage` for all pids and serves results over XPC. This is the correct way to get footprint, and also exact per-process CPU for all 330. It costs a one-time admin approval.
4. Show "—" for the memory of foreign-uid processes, and show CPU, energy and disk from coalitions.

### Decision
- **Can we get CPU time for root-owned processes without root? Yes.** Coalition `cpu_time`, within about 1% of `ps` (see table in C). Energy, disk bytes and GPU time come free.
- **Can we get memory for root-owned processes without root? No,** except by spawning setuid `ps` for RSS. Footprint needs a privileged helper.
- Drop libsysmon from the plan. It is gated by a restricted entitlement that AMFI enforces.
