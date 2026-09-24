# M0 — Private API Spikes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove, on this machine (M1 Max MacBook Pro, macOS 26.5), that every private or undocumented data source in the spec works without root, and record exact API shapes, keys, and costs in `FINDINGS.md`.

**Architecture:** A throwaway SwiftPM package `Spikes/` with one C target, `CPrivate`, that declares private symbols and holds the SMC C shim, plus one executable per data source. Each executable prints human-readable output that is checked against a reference tool (Activity Monitor, `powermetrics`, `nettop`, `ioreg`). The SDK ships `.tbd` stubs for `libIOReport`, `libsysmon`, and `NetworkStatistics.framework`, so everything links directly with no `dlopen`.

**Tech Stack:** Swift 6.3 toolchain (language mode 5 for spikes), SwiftPM, C, IOKit, CoreFoundation, XPC.

**Spec:** `SPEC.md` (repo root)

## Global Constraints

- Apple Silicon only. Dev machine: M1 Max, macOS 26.5, Xcode 26.6. Deployment floor macOS 14.
- No sandbox, no root, no privileged helper. Every spike must run as the normal user.
- Private APIs are allowed. Record every symbol, key, and magic number used in `FINDINGS.md`.
- Spikes are throwaway exploration. Verification means comparing against a reference tool, not unit tests. TDD starts in M1 (`MonitorCore`).
- Timebox: half a day per spike. If a spike blows the timebox, stop, write down what failed in `FINDINGS.md`, and move on. Task 8 handles the decision.
- Keep terminal output under about 100 lines. Pipe through `head` or `grep`.
- Commits end with the trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## File Structure

```
system-monitor/
  .gitignore
  FINDINGS.md                         M0 results (Task 8 consolidates)
  Spikes/
    Package.swift
    Sources/
      CPrivate/
        include/Responsibility.h      responsibility_get_pid_responsible_for_pid
        include/Sysmon.h              libsysmon decls
        include/IOReport.h            libIOReport decls
        include/HIDPrivate.h          private IOHID decls (public types reused)
        include/SMC.h                 smc_open/smc_read/smc_key_at
        include/NStat.h               NetworkStatistics decls
        shim.c                        empty TU (C target needs one source)
        smc.c                         AppleSMC user-client calls
      spike-procs/main.swift          proc_pid_rusage sweep + responsible-PID grouping
      spike-sysmon/main.swift         libsysmon discovery
      spike-ioreport/main.swift       watts, P/E cluster + GPU residency
      spike-temps/main.swift          HID temperature sensors
      spike-smc/main.swift            fans + SMC temp keys
      spike-gpu-apps/main.swift       per-app GPU time from AGX user clients
      spike-nstat/main.swift          per-app network bytes
```

`CPrivate` uses umbrella-directory mode: there is no `CPrivate.h`, so SwiftPM imports every header in `include/`. Each task adds its header with no other edits.

---

### Task 1: Scaffold + process sweep spike

Proves `proc_pid_rusage` coverage, meaning how many PIDs return EPERM when not root. Also proves responsible-PID app grouping and measures the cost of a full sweep.

**Files:**
- Create: `.gitignore`, `Spikes/Package.swift`, `Spikes/Sources/CPrivate/shim.c`, `Spikes/Sources/CPrivate/include/Responsibility.h`, `Spikes/Sources/spike-procs/main.swift`, `FINDINGS.md`

**Interfaces:**
- Produces: package layout, the `CPrivate` module, and the `privateLinks` linker settings that later tasks reuse. Later tasks append one `.executableTarget` each.

- [ ] **Step 1: Write `.gitignore`**

```gitignore
.build/
.swiftpm/
DerivedData/
xcuserdata/
*.xcuserstate
.DS_Store
```

- [ ] **Step 2: Write `Spikes/Package.swift`**

```swift
// swift-tools-version:6.0
import PackageDescription

// ld applies -syslibroot to absolute -F paths, so this resolves inside the SDK.
let privateLinks: [LinkerSetting] = [
    .linkedFramework("IOKit"),
    .linkedLibrary("IOReport"),
    .linkedLibrary("sysmon"),
    .unsafeFlags(["-F/System/Library/PrivateFrameworks", "-framework", "NetworkStatistics"]),
]

let package = Package(
    name: "Spikes",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CPrivate", linkerSettings: privateLinks),
        .executableTarget(name: "spike-procs", dependencies: ["CPrivate"]),
    ],
    swiftLanguageModes: [.v5]
)
```

- [ ] **Step 3: Write the C target files**

`Spikes/Sources/CPrivate/shim.c`:
```c
// Intentionally empty: SwiftPM C targets need at least one translation unit.
```

`Spikes/Sources/CPrivate/include/Responsibility.h`:
```c
#pragma once
#include <sys/types.h>

// libquarantine (re-exported by libSystem). Returns the PID macOS attributes
// a process's resource use to (e.g. Chrome helpers -> Chrome). <= 0 on failure.
pid_t responsibility_get_pid_responsible_for_pid(pid_t pid);
```

- [ ] **Step 4: Write `Spikes/Sources/spike-procs/main.swift`**

```swift
import Foundation
import Darwin
import CPrivate

struct Sample { var cpuNs: UInt64; var footprint: UInt64; var diskR: UInt64; var diskW: UInt64; var energyNj: UInt64 }

// On Apple Silicon ri_user_time/ri_system_time are mach ticks, not ns.
let timebase: mach_timebase_info_data_t = { var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t }()
func ticksToNs(_ t: UInt64) -> UInt64 { t * UInt64(timebase.numer) / UInt64(timebase.denom) }

func allPids() -> [pid_t] {
    let n = proc_listallpids(nil, 0)
    var pids = [pid_t](repeating: 0, count: Int(n) + 64)
    let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    return Array(pids.prefix(Int(max(got, 0))))
}

func rusage(_ pid: pid_t) -> Result<Sample, POSIXErrorCode> {
    var info = rusage_info_v4()
    let rc = withUnsafeMutablePointer(to: &info) { p in
        p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    if rc != 0 { return .failure(POSIXErrorCode(rawValue: errno) ?? .EINVAL) }
    return .success(Sample(cpuNs: ticksToNs(info.ri_user_time + info.ri_system_time),
                           footprint: info.ri_phys_footprint,
                           diskR: info.ri_diskio_bytesread, diskW: info.ri_diskio_byteswritten,
                           energyNj: info.ri_billed_energy))
}

func path(_ pid: pid_t) -> String? {
    var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
}

func name(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 256)
    return proc_name(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : "pid \(pid)"
}

var appNameCache: [pid_t: String] = [:]
func appName(owner pid: pid_t) -> String {
    if let c = appNameCache[pid] { return c }
    var n = name(pid)
    if let p = path(pid), let r = p.range(of: ".app/") {
        n = URL(fileURLWithPath: String(p[..<r.lowerBound])).lastPathComponent
    }
    appNameCache[pid] = n
    return n
}

func sweep() -> (ok: [pid_t: Sample], denied: [pid_t], otherErr: Int) {
    var ok: [pid_t: Sample] = [:]; var denied: [pid_t] = []; var other = 0
    for pid in allPids() {
        switch rusage(pid) {
        case .success(let s): ok[pid] = s
        case .failure(.EPERM): denied.append(pid)
        case .failure: other += 1
        }
    }
    return (ok, denied, other)
}

let clock = ContinuousClock()
var first: (ok: [pid_t: Sample], denied: [pid_t], otherErr: Int)!
let sweepCost = clock.measure { first = sweep() }
let t0 = Date()
Thread.sleep(forTimeInterval: 2)
let second = sweep()
let dt = Date().timeIntervalSince(t0)

print("pids ok=\(first.ok.count) EPERM=\(first.denied.count) other=\(first.otherErr) sweep=\(sweepCost)")
print("EPERM sample:", first.denied.prefix(12).map { "\($0):\(name($0))" }.joined(separator: ", "))

struct Agg { var cpu = 0.0; var watts = 0.0; var mem: UInt64 = 0; var diskBps = 0.0; var procs = 0 }
var apps: [String: Agg] = [:]
var respFail = 0
for (pid, b) in second.ok {
    guard let a = first.ok[pid] else { continue }
    let resp = responsibility_get_pid_responsible_for_pid(pid)
    if resp <= 0 { respFail += 1 }
    let key = appName(owner: resp > 0 ? resp : pid)
    var g = apps[key, default: Agg()]
    g.cpu += Double(b.cpuNs &- a.cpuNs) / (dt * 1e9) * 100
    g.watts += Double(b.energyNj &- a.energyNj) / (dt * 1e9)
    g.mem += b.footprint
    g.diskBps += Double((b.diskR &- a.diskR) &+ (b.diskW &- a.diskW)) / dt
    g.procs += 1
    apps[key] = g
}
print("apps=\(apps.count) responsibleFail=\(respFail)")
func row(_ k: String, _ v: String) -> String { k.padding(toLength: 34, withPad: " ", startingAt: 0) + v }
print("-- top CPU (%)");      for (k, v) in apps.sorted(by: { $0.value.cpu > $1.value.cpu }).prefix(10) { print(row(k, String(format: "%6.1f  procs=%d", v.cpu, v.procs))) }
print("-- top energy (W)");   for (k, v) in apps.sorted(by: { $0.value.watts > $1.value.watts }).prefix(5) { print(row(k, String(format: "%6.2f", v.watts))) }
print("-- top footprint (MB)"); for (k, v) in apps.sorted(by: { $0.value.mem > $1.value.mem }).prefix(5) { print(row(k, String(format: "%8.0f", Double(v.mem) / 1_048_576))) }
print("-- top disk (KB/s)");  for (k, v) in apps.sorted(by: { $0.value.diskBps > $1.value.diskBps }).prefix(5) { print(row(k, String(format: "%8.0f", v.diskBps / 1024))) }
```

- [ ] **Step 5: Build and run**

Run: `cd Spikes && swift build 2>&1 | grep -E 'error|warning: unre|Compiling|Build' | tail -5 && swift run -c release spike-procs 2>&1 | tail -40`
Expected: build succeeds. Output shows `pids ok=… EPERM=…`. Chrome/Electron helpers collapse into one app row with `procs>1`.

- [ ] **Step 6: Verify against Activity Monitor**

Open Activity Monitor (CPU tab, View → All Processes, Hierarchically). Run the spike again while it's open.
Check:
- Top CPU apps roughly match. Use ±30% relative tolerance, since the sampling windows differ.
- Energy ranking is plausible next to the Energy tab.
- Footprint MB ≈ Activity Monitor's "Memory" column for top apps.
- EPERM list: note whether `kernel_task`, `WindowServer`, `launchd`, and `mds_stores` are denied.

- [ ] **Step 7: Start `FINDINGS.md` and record results**

```markdown
# M0 Findings (M1 Max, macOS 26.5)

## procs — proc_pid_rusage + responsible PID
- Status: ✅/⚠️/❌
- PIDs ok / EPERM / other: …
- Denied notable: …
- Sweep cost (N pids): … ms
- Grouping: responsible PID works? failures: …
- Accuracy vs Activity Monitor: …
- Notes / gotchas: mach ticks → ns via timebase (confirmed?)
```

- [ ] **Step 8: Commit**

```bash
git add .gitignore FINDINGS.md Spikes
git commit -m "spike: proc_pid_rusage sweep and responsible-PID grouping"
```

---

### Task 2: libsysmon spike (root-process visibility)

This is the highest-risk spike. It checks whether `sysmond` answers an unentitled client and whether the answer includes root-owned processes. Signatures come from reverse engineering, so the spike discovers attribute IDs by dumping every row value.

**Files:**
- Create: `Spikes/Sources/CPrivate/include/Sysmon.h`, `Spikes/Sources/spike-sysmon/main.swift`
- Modify: `Spikes/Package.swift` (add target)

**Interfaces:**
- Consumes: `CPrivate` module (Task 1).
- Produces: in `FINDINGS.md`, the request type and the attribute IDs for pid, name, CPU time, footprint, disk bytes, and energy (whichever exist).

- [ ] **Step 1: Write `Spikes/Sources/CPrivate/include/Sysmon.h`**

```c
#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <xpc/xpc.h>

// Reverse-engineered libsysmon (/usr/lib/libsysmon.dylib). Unverified: the spike validates.
typedef void *sysmon_request_t;
typedef void *sysmon_table_t;
typedef void *sysmon_row_t;

sysmon_request_t sysmon_request_create(uint8_t type, void (^handler)(sysmon_table_t table));
void sysmon_request_add_attribute(sysmon_request_t req, uint32_t attr);
void sysmon_request_execute(sysmon_request_t req);
void sysmon_request_cancel(sysmon_request_t req);
uint64_t sysmon_table_get_count(sysmon_table_t table);
sysmon_row_t sysmon_table_get_row(sysmon_table_t table, uint64_t index);
xpc_object_t sysmon_row_get_value(sysmon_row_t row, uint32_t attr);
void sysmon_row_apply(sysmon_row_t row, bool (^block)(uint32_t attr, xpc_object_t value));
void sysmon_release(void *object);
```

- [ ] **Step 2: Add the target to `Spikes/Package.swift`**

Inside `targets: [...]`, after the `spike-procs` line, add:
```swift
        .executableTarget(name: "spike-sysmon", dependencies: ["CPrivate"]),
```

- [ ] **Step 3: Write `Spikes/Sources/spike-sysmon/main.swift`**

```swift
import Foundation
import CPrivate

let me = getpid()

func describe(_ v: xpc_object_t) -> String {
    let d = xpc_copy_description(v)
    defer { free(d) }
    return String(cString: d)
}

/// Runs one request. Returns nil on timeout (no reply from sysmond).
func run(type: UInt8, attrs: [UInt32], timeout: Double = 3) -> [[UInt32: String]]? {
    let sem = DispatchSemaphore(value: 0)
    var rows: [[UInt32: String]] = []
    guard let req = sysmon_request_create(type, { table in
        defer { sem.signal() }
        guard let table else { return }
        for i in 0..<sysmon_table_get_count(table) {
            guard let row = sysmon_table_get_row(table, i) else { continue }
            var r: [UInt32: String] = [:]
            sysmon_row_apply(row) { attr, value in
                if let value { r[attr] = describe(value) }
                return true
            }
            rows.append(r)
        }
    }) else { print("type \(type): create returned NULL"); return nil }
    for a in attrs { sysmon_request_add_attribute(req, a) }
    sysmon_request_execute(req)
    let ok = sem.wait(timeout: .now() + timeout) == .success
    sysmon_release(req)
    return ok ? rows : nil
}

let allAttrs = Array(UInt32(0)..<UInt32(128))
for type in UInt8(1)...UInt8(4) {
    guard let rows = run(type: type, attrs: allAttrs) else { print("type \(type): no reply (timeout)"); continue }
    print("type \(type): rows=\(rows.count) attrsInRow0=\(rows.first?.count ?? 0)")
    // Find our own process row: some int attr equals our pid.
    if let mine = rows.first(where: { $0.values.contains { $0.hasSuffix(": \(me)") } }) {
        print("  own-pid row (pid=\(me)):")
        for (k, v) in mine.sorted(by: { $0.key < $1.key }) { print("   [\(k)] \(v.prefix(90))") }
    }
    // Root-process visibility: look for kernel_task / WindowServer names.
    for probe in ["kernel_task", "WindowServer", "mds_stores"] {
        let hit = rows.first { $0.values.contains { $0.contains(probe) } }
        print("  \(probe): \(hit.map { "found, \($0.count) attrs" } ?? "absent")")
    }
}
```

- [ ] **Step 4: Build and run**

Run: `cd Spikes && swift build 2>&1 | grep -E 'error' | head -5; swift run spike-sysmon 2>&1 | head -80`
Expected is one of:
- (a) Some type returns rows including `kernel_task` and `WindowServer` with non-empty attrs. **Success.**
- (b) Every type times out or returns 0 rows. The client is probably rejected (missing entitlement).
- (c) Crash. A signature is wrong.

- [ ] **Step 5: If (b), check for rejection in the system log**

Run: `log show --last 2m --style compact --predicate 'process == "sysmond" OR subsystem CONTAINS "sysmon"' 2>/dev/null | tail -20`
Record any entitlement or "not permitted" line verbatim.

- [ ] **Step 6: If (a), map the attribute IDs**

Compare the own-pid row values to known facts:
- pid is `me`
- name is `spike-sysmon`
- CPU time: compare with the `ps -o time= -p <pid>` equivalent
- footprint: compare with `footprint <pid>` or Activity Monitor
Run a second request with only the identified attrs, and check that the `kernel_task` row has CPU time and footprint values.

- [ ] **Step 7: Record in `FINDINGS.md`**

```markdown
## sysmon — libsysmon / sysmond
- Status: ✅/⚠️/❌ (outcome a/b/c)
- Request type for processes: …
- Attr IDs: pid=… name=… cpu_time=… (unit?) footprint=… disk_r=… disk_w=… energy=… responsible_pid=…
- Root procs visible (kernel_task/WindowServer)? …
- Reply latency: … ms, rows: …
- Log lines (if rejected): …
```

- [ ] **Step 8: Commit**

```bash
git add Spikes FINDINGS.md
git commit -m "spike: libsysmon discovery"
```

---

### Task 3: IOReport spike (watts, P/E clusters, GPU %)

**Files:**
- Create: `Spikes/Sources/CPrivate/include/IOReport.h`, `Spikes/Sources/spike-ioreport/main.swift`
- Modify: `Spikes/Package.swift` (add target)

**Interfaces:**
- Consumes: `CPrivate`.
- Produces: in `FINDINGS.md`, exact group/subgroup/channel names, unit labels, the idle state names, and the sample cost.

- [ ] **Step 1: Write `Spikes/Sources/CPrivate/include/IOReport.h`**

```c
#pragma once
#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>

// libIOReport (SDK ships libIOReport.tbd). Implicit bridging: Create/Copy => +1, Get => +0.
CF_IMPLICIT_BRIDGING_ENABLED
typedef CFTypeRef IOReportSubscriptionRef;

CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef group, CFStringRef subgroup, uint64_t a, uint64_t b, uint64_t c);
void IOReportMergeChannels(CFMutableDictionaryRef into, CFMutableDictionaryRef from, CFTypeRef unused);
IOReportSubscriptionRef IOReportCreateSubscription(void *unused, CFMutableDictionaryRef desired, CFMutableDictionaryRef *subscribed, uint64_t channelID, CFTypeRef unused2);
CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef sub, CFMutableDictionaryRef subscribed, CFTypeRef unused);
CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef prev, CFDictionaryRef cur, CFTypeRef unused);

CFStringRef IOReportChannelGetGroup(CFDictionaryRef ch);
CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef ch);
CFStringRef IOReportChannelGetChannelName(CFDictionaryRef ch);
CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef ch);
int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef ch, int32_t index);
int32_t IOReportStateGetCount(CFDictionaryRef ch);
CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef ch, int32_t index);
int64_t IOReportStateGetResidency(CFDictionaryRef ch, int32_t index);
CF_IMPLICIT_BRIDGING_DISABLED
```

- [ ] **Step 2: Add the target to `Spikes/Package.swift`**

```swift
        .executableTarget(name: "spike-ioreport", dependencies: ["CPrivate"]),
```

- [ ] **Step 3: Write `Spikes/Sources/spike-ioreport/main.swift`**

```swift
import Foundation
import CPrivate

func pad(_ s: String, _ n: Int = 30) -> String { s.padding(toLength: n, withPad: " ", startingAt: 0) }

let desired = IOReportCopyChannelsInGroup("Energy Model" as CFString, nil, 0, 0, 0)!
IOReportMergeChannels(desired, IOReportCopyChannelsInGroup("CPU Stats" as CFString, "CPU Complex Performance States" as CFString, 0, 0, 0), nil)
IOReportMergeChannels(desired, IOReportCopyChannelsInGroup("GPU Stats" as CFString, "GPU Performance States" as CFString, 0, 0, 0), nil)

var subscribedRef: Unmanaged<CFMutableDictionary>?
guard let sub = IOReportCreateSubscription(nil, desired, &subscribedRef, 0, nil), let subscribedU = subscribedRef else {
    print("IOReportCreateSubscription failed"); exit(1)
}
let subscribed = subscribedU.takeUnretainedValue()

let clock = ContinuousClock()
var s0: CFDictionary!
let sampleCost = clock.measure { s0 = IOReportCreateSamples(sub, subscribed, nil) }
let t0 = Date()
Thread.sleep(forTimeInterval: 1)
let s1 = IOReportCreateSamples(sub, subscribed, nil)!
let dt = Date().timeIntervalSince(t0)
let delta = IOReportCreateSamplesDelta(s0, s1, nil)!
let channels = ((delta as NSDictionary)["IOReportChannels"] as? [NSDictionary]) ?? []
print("channels=\(channels.count) sampleCost=\(sampleCost) dt=\(String(format: "%.3f", dt))s")

let idleStates: Set<String> = ["IDLE", "OFF", "DOWN"]
var seenStateNames = Set<String>()
for nsCh in channels {
    let ch = nsCh as CFDictionary
    let group = IOReportChannelGetGroup(ch) as String? ?? ""
    let name = IOReportChannelGetChannelName(ch) as String? ?? ""
    if group == "Energy Model" {
        let unit = IOReportChannelGetUnitLabel(ch) as String? ?? ""
        let raw = Double(IOReportSimpleGetIntegerValue(ch, 0))
        let div: Double = ["mJ": 1e3, "uJ": 1e6, "nJ": 1e9][unit] ?? 1
        let watts = raw / div / dt
        if watts > 0.001 { print("  E  " + pad(name) + String(format: "%7.3f W  [%@]", watts, unit as NSString)) }
    } else {
        var total: Int64 = 0, idle: Int64 = 0
        for i in 0..<IOReportStateGetCount(ch) {
            let s = IOReportStateGetNameForIndex(ch, i) as String? ?? ""
            let r = IOReportStateGetResidency(ch, i)
            total += r
            if idleStates.contains(s) { idle += r }
            seenStateNames.insert(s)
        }
        let active = total > 0 ? Double(total - idle) / Double(total) * 100 : 0
        print("  R  " + pad("\(group)/\(name)") + String(format: "%6.1f %% active", active))
    }
}
print("state names seen:", seenStateNames.sorted().prefix(30).joined(separator: " "))
```

- [ ] **Step 4: Build and run under load**

Run: `cd Spikes && swift build 2>&1 | grep error | head; (yes > /dev/null & P=$!; sleep 0.5; swift run spike-ioreport 2>&1 | head -60; kill $P)`
Expected: `E` lines for CPU/GPU/ANE/DRAM-type channels in watts. `R` lines for `ECPU`, `PCPU`, `PCPU1`, `GPUPH`. With `yes` running, one P or E cluster shows noticeably non-zero activity.

- [ ] **Step 5: Verify against `powermetrics`**

The user runs this in their own terminal (it needs sudo, so the agent must not enter a password):
```bash
sudo powermetrics --samplers cpu_power,gpu_power -i 1000 -n 1 | grep -E 'Power|active residency|HW active'
```
Compare CPU, GPU, and ANE watts and the cluster active residency. Values should be the same order of magnitude, within about ±30%.

- [ ] **Step 6: Record in `FINDINGS.md`**

```markdown
## ioreport — libIOReport
- Status: …
- Energy channel names → metric: CPU=… GPU=… ANE=… DRAM=… (units: …)
- Cluster channels: … ; GPU channel: … ; idle state names: …
- Sample cost: … ; accuracy vs powermetrics: …
- Frequencies: not done (residency only). Needed? P-state→MHz table from IORegistry pmgr `voltage-states*`: defer to M3.
```

- [ ] **Step 7: Commit**

```bash
git add Spikes FINDINGS.md
git commit -m "spike: IOReport power and residency"
```

---

### Task 4: HID temperature spike

**Files:**
- Create: `Spikes/Sources/CPrivate/include/HIDPrivate.h`, `Spikes/Sources/spike-temps/main.swift`
- Modify: `Spikes/Package.swift` (add target)

**Interfaces:**
- Consumes: `CPrivate`. Public types `IOHIDEventSystemClientRef` and `IOHIDServiceClientRef` come from `<IOKit/hidsystem/…>`.
- Produces: in `FINDINGS.md`, the full sensor name list and the name→group mapping (CPU P, CPU E, GPU, SSD, battery).

- [ ] **Step 1: Write `Spikes/Sources/CPrivate/include/HIDPrivate.h`**

```c
#pragma once
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>

// Private IOHID pieces not in public headers. Public ones (CopyServices,
// ServiceClientCopyProperty, CreateSimpleClient) come from the includes above.
CF_IMPLICIT_BRIDGING_ENABLED
typedef struct CF_BRIDGED_TYPE(id) __IOHIDEvent *IOHIDEventRef;

IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
int32_t IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef matching);
IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timestamp);
double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);
CF_IMPLICIT_BRIDGING_DISABLED

enum { kSMHIDEventTypeTemperature = 15 };  // field = type << 16
```

- [ ] **Step 2: Add the target to `Spikes/Package.swift`**

```swift
        .executableTarget(name: "spike-temps", dependencies: ["CPrivate"]),
```

- [ ] **Step 3: Write `Spikes/Sources/spike-temps/main.swift`**

```swift
import Foundation
import IOKit.hidsystem
import CPrivate

let type = Int64(kSMHIDEventTypeTemperature)
let field = Int32(type << 16)

let client: IOHIDEventSystemClient
if let c = IOHIDEventSystemClientCreate(kCFAllocatorDefault) { client = c; print("client: full") }
else { client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault); print("client: simple (fallback)") }

let matching = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary
_ = IOHIDEventSystemClientSetMatching(client, matching)
let services = (IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient]) ?? []

let clock = ContinuousClock()
var readings: [(String, Double)] = []
let cost = clock.measure {
    for svc in services {
        let name = IOHIDServiceClientCopyProperty(svc, "Product" as CFString) as? String ?? "?"
        guard let ev = IOHIDServiceClientCopyEvent(svc, type, 0, 0) else { continue }
        readings.append((name, IOHIDEventGetFloatValue(ev, field)))
    }
}
print("services=\(services.count) readings=\(readings.count) cost=\(cost)")
for (n, v) in readings.sorted(by: { $0.0 < $1.0 }) {
    print(n.padding(toLength: 36, withPad: " ", startingAt: 0) + String(format: "%6.1f °C", v))
}
print("thermalState:", ProcessInfo.processInfo.thermalState.rawValue)
```

- [ ] **Step 4: Build and run under load**

Run: `cd Spikes && swift build 2>&1 | grep error | head; swift run spike-temps 2>&1 | head -80`
Then run once more with `yes > /dev/null &` running on 8 cores for 20s first (`for i in $(seq 8); do yes >/dev/null & done; sleep 20; swift run spike-temps | head -40; killall yes`).
Expected: 20–80 sensors between 20 and 110 °C. Sensors named like `pACC …`/`eACC …`/`PMU tdie…` rise under load, while `NAND …` and `gas gauge battery` stay steady.

- [ ] **Step 5: Record in `FINDINGS.md`**

```markdown
## temps — IOHID
- Status: … ; client type: full/simple ; sensors: … ; cost: …
- Mapping: CPU-P = names matching … ; CPU-E = … ; GPU = … ; SSD = … ; battery = …
- Under-load delta confirms mapping: …
- Garbage/stuck sensors to filter: …
```

- [ ] **Step 6: Commit**

```bash
git add Spikes FINDINGS.md
git commit -m "spike: HID temperature sensors"
```

---

### Task 5: SMC spike (fans + SMC temps)

**Files:**
- Create: `Spikes/Sources/CPrivate/include/SMC.h`, `Spikes/Sources/CPrivate/smc.c`, `Spikes/Sources/spike-smc/main.swift`
- Modify: `Spikes/Package.swift` (add target)

**Interfaces:**
- Consumes: `CPrivate`.
- Produces: `smc_open() -> io_connect_t`, `smc_read(conn, key, &type, bytes, &size) -> Int32` (0 means ok), `smc_key_at(conn, index, out5) -> Int32`, `smc_close(conn)`. M3 reuses these.

- [ ] **Step 1: Write `Spikes/Sources/CPrivate/include/SMC.h`**

```c
#pragma once
#include <IOKit/IOKitLib.h>
#include <stdint.h>

io_connect_t smc_open(void);                    // 0 on failure
void smc_close(io_connect_t conn);
// Reads a 4-char key. type = FourCC data type (e.g. 'flt ', 'ui8 '). bytes must hold 32.
int32_t smc_read(io_connect_t conn, const char *key, uint32_t *type, uint8_t *bytes, uint32_t *size);
// Key name at index (0..<#KEY) into out[5] (NUL-terminated).
int32_t smc_key_at(io_connect_t conn, uint32_t index, char *out);
```

- [ ] **Step 2: Write `Spikes/Sources/CPrivate/smc.c`**

```c
#include "SMC.h"
#include <mach/mach.h>
#include <string.h>

// AppleSMC user-client struct layout (selector 2). Must be 80 bytes.
typedef struct { char major, minor, build, reserved; uint16_t release; } SMCVers;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { uint32_t dataSize, dataType; uint8_t dataAttributes; } SMCKeyInfo;
typedef struct {
    uint32_t key;
    SMCVers vers;
    SMCPLimit pLimitData;
    SMCKeyInfo keyInfo;
    uint8_t result, status, data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCParam;
_Static_assert(sizeof(SMCParam) == 80, "SMCParam layout");

enum { kSMCUserClient = 2, kSMCReadKey = 5, kSMCGetKeyFromIndex = 8, kSMCGetKeyInfo = 9 };

static uint32_t fourcc(const char *s) {
    return ((uint32_t)(uint8_t)s[0] << 24) | ((uint32_t)(uint8_t)s[1] << 16) |
           ((uint32_t)(uint8_t)s[2] << 8) | (uint32_t)(uint8_t)s[3];
}

static kern_return_t call(io_connect_t c, SMCParam *in, SMCParam *out) {
    size_t outSize = sizeof(SMCParam);
    return IOConnectCallStructMethod(c, kSMCUserClient, in, sizeof(SMCParam), out, &outSize);
}

io_connect_t smc_open(void) {
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return 0;
    io_connect_t conn = 0;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &conn);
    IOObjectRelease(svc);
    return kr == KERN_SUCCESS ? conn : 0;
}

void smc_close(io_connect_t conn) { if (conn) IOServiceClose(conn); }

int32_t smc_read(io_connect_t c, const char *key, uint32_t *type, uint8_t *bytes, uint32_t *size) {
    SMCParam in = {0}, out = {0};
    in.key = fourcc(key);
    in.data8 = kSMCGetKeyInfo;
    if (call(c, &in, &out) != KERN_SUCCESS || out.result != 0) return -1;
    uint32_t sz = out.keyInfo.dataSize;
    *type = out.keyInfo.dataType;
    in.keyInfo.dataSize = sz;
    in.data8 = kSMCReadKey;
    memset(&out, 0, sizeof out);
    if (call(c, &in, &out) != KERN_SUCCESS || out.result != 0) return -2;
    if (sz > 32) sz = 32;
    memcpy(bytes, out.bytes, sz);
    *size = sz;
    return 0;
}

int32_t smc_key_at(io_connect_t c, uint32_t index, char *outKey) {
    SMCParam in = {0}, out = {0};
    in.data8 = kSMCGetKeyFromIndex;
    in.data32 = index;
    if (call(c, &in, &out) != KERN_SUCCESS || out.result != 0) return -1;
    outKey[0] = (char)(out.key >> 24); outKey[1] = (char)(out.key >> 16);
    outKey[2] = (char)(out.key >> 8);  outKey[3] = (char)out.key; outKey[4] = 0;
    return 0;
}
```

- [ ] **Step 3: Add the target to `Spikes/Package.swift`**

```swift
        .executableTarget(name: "spike-smc", dependencies: ["CPrivate"]),
```

- [ ] **Step 4: Write `Spikes/Sources/spike-smc/main.swift`**

```swift
import Foundation
import CPrivate

let conn = smc_open()
guard conn != 0 else { print("smc_open failed"); exit(1) }
defer { smc_close(conn) }

func fourccString(_ v: UInt32) -> String {
    String(bytes: [24, 16, 8, 0].map { UInt8((v >> $0) & 0xff) }, encoding: .ascii) ?? "????"
}

func read(_ key: String) -> (type: String, bytes: [UInt8])? {
    var type: UInt32 = 0, size: UInt32 = 0
    var buf = [UInt8](repeating: 0, count: 32)
    guard smc_read(conn, key, &type, &buf, &size) == 0 else { return nil }
    return (fourccString(type), Array(buf.prefix(Int(size))))
}

// Apple Silicon: 'flt ' is little-endian Float32; integer types are big-endian.
func value(_ r: (type: String, bytes: [UInt8])) -> Double? {
    let b = r.bytes
    switch r.type {
    case "flt " where b.count >= 4: return Double(Float(bitPattern: UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24))
    case "ui8 " where b.count >= 1: return Double(b[0])
    case "ui16" where b.count >= 2: return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
    case "ui32" where b.count >= 4: return Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
    default: return nil
    }
}

let fanCount = read("FNum").flatMap(value).map(Int.init) ?? 0
print("fans=\(fanCount)")
for i in 0..<fanCount {
    let parts = ["Ac", "Mn", "Mx", "Tg"].map { s -> String in
        let r = read("F\(i)\(s)")
        return "\(s)=\(r.flatMap(value).map { String(format: "%.0f", $0) } ?? "–")(\(r?.type ?? "?"))"
    }
    print("  F\(i): " + parts.joined(separator: " "))
}

let keyCount = read("#KEY").flatMap(value).map(Int.init) ?? 0
var temps: [(String, Double)] = []
let clock = ContinuousClock()
let enumCost = clock.measure {
    var k = [CChar](repeating: 0, count: 5)
    for idx in 0..<keyCount {
        guard smc_key_at(conn, UInt32(idx), &k) == 0 else { continue }
        let key = String(cString: k)
        guard key.hasPrefix("T"), let r = read(key), r.type == "flt ", let v = value(r), v > 5, v < 130 else { continue }
        temps.append((key, v))
    }
}
print("keys=\(keyCount) plausibleTempKeys=\(temps.count) enumCost=\(enumCost)")
print(temps.prefix(60).map { "\($0.0)=\(String(format: "%.1f", $0.1))" }.joined(separator: " "))
```

- [ ] **Step 5: Build and run**

Run: `cd Spikes && swift build 2>&1 | grep error | head; swift run spike-smc 2>&1 | head -30`
Expected on M1 Max MBP: `fans=2`, with `F0Ac`/`F1Ac` giving RPM as `flt ` (0 is valid when the fans are stopped at idle). Several dozen `T…` keys between 20 and 100.

- [ ] **Step 6: Verify fans under load**

Run 8× `yes` for about 60s (as in Task 4) and re-run the spike. `F0Ac` should rise above 0 or above the idle RPM. Kill `yes` afterward (`killall yes`).

- [ ] **Step 7: Record in `FINDINGS.md`**

```markdown
## smc — AppleSMC
- Status: … ; fans: … ; RPM type: … ; min/max: …
- SMC temp keys worth using (vs HID): …
- Key enumeration cost: … (M3: enumerate once at startup, cache key list)
```

- [ ] **Step 8: Commit**

```bash
git add Spikes FINDINGS.md
git commit -m "spike: SMC fans and temperature keys"
```

---

### Task 6: Per-app GPU spike (AGX user clients)

Public IOKit only. There are no private declarations.

**Files:**
- Create: `Spikes/Sources/spike-gpu-apps/main.swift`
- Modify: `Spikes/Package.swift` (add target)

**Interfaces:**
- Produces: in `FINDINGS.md`, the property names for the creator PID and accumulated GPU time, and the device utilization key.

- [ ] **Step 1: Add the target to `Spikes/Package.swift`**

```swift
        .executableTarget(name: "spike-gpu-apps", dependencies: ["CPrivate"]),
```

- [ ] **Step 2: Write `Spikes/Sources/spike-gpu-apps/main.swift`**

```swift
import Foundation
import IOKit
import CPrivate

func props(_ e: io_registry_entry_t) -> [String: Any] {
    var u: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(e, &u, kCFAllocatorDefault, 0) == KERN_SUCCESS, let d = u?.takeRetainedValue() else { return [:] }
    return d as? [String: Any] ?? [:]
}

let accel = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
guard accel != 0 else { print("no AGXAccelerator"); exit(1) }

let perf = props(accel)["PerformanceStatistics"] as? [String: Any] ?? [:]
print("PerformanceStatistics keys:", perf.keys.sorted().joined(separator: ", "))
print("Device Utilization %:", perf["Device Utilization %"] ?? "–")

/// pid -> (name, accumulated GPU ns)
func gpuTimes(dumpFirst: Bool) -> [Int32: (String, UInt64)] {
    var out: [Int32: (String, UInt64)] = [:]
    var it: io_iterator_t = 0
    guard IORegistryEntryGetChildIterator(accel, kIOServicePlane, &it) == KERN_SUCCESS else { return out }
    defer { IOObjectRelease(it) }
    var dumped = !dumpFirst
    while case let child = IOIteratorNext(it), child != 0 {
        defer { IOObjectRelease(child) }
        let p = props(child)
        guard let creator = p["IOUserClientCreator"] as? String else { continue }  // "pid 123, Name"
        if !dumped, p["AppUsage"] != nil { print("sample client props:", p.keys.sorted().joined(separator: ", ")); dumped = true }
        let pidStr = creator.split(separator: ",").first?.split(separator: " ").last
        guard let pid = pidStr.flatMap({ Int32($0) }) else { continue }
        let name = creator.split(separator: ",", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? "?"
        let usage = p["AppUsage"] as? [[String: Any]] ?? []
        let ns = usage.reduce(UInt64(0)) { $0 + (($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0) }
        out[pid, default: (name, 0)].1 += ns
    }
    return out
}

let clock = ContinuousClock()
var a: [Int32: (String, UInt64)] = [:]
let cost = clock.measure { a = gpuTimes(dumpFirst: true) }
Thread.sleep(forTimeInterval: 1)
let b = gpuTimes(dumpFirst: false)
print("clients(pids)=\(a.count) walkCost=\(cost)")
let rows = b.compactMap { pid, v -> (String, Double)? in
    guard let old = a[pid] else { return nil }
    return ("\(v.0) [\(pid)]", Double(v.1 &- old.1) / 1e9 * 100)   // % of one GPU over 1 s
}.sorted { $0.1 > $1.1 }
for (n, pct) in rows.prefix(10) { print(n.padding(toLength: 40, withPad: " ", startingAt: 0) + String(format: "%6.1f %%", pct)) }
```

- [ ] **Step 3: Build and run with GPU load**

Run: `cd Spikes && swift build 2>&1 | grep error | head; swift run spike-gpu-apps 2>&1 | head -30`
Play a WebGL demo or 4K video in a browser first so there is GPU load.
Expected: `WindowServer` plus the browser GPU process appear with non-zero %. `Device Utilization %` is present.

- [ ] **Step 4: Verify against Activity Monitor**

Activity Monitor → Window → GPU History, plus the GPU % column in the CPU tab (View → Columns → % GPU). The top apps should match.

- [ ] **Step 5: Record in `FINDINGS.md`**

```markdown
## gpu-apps — AGXDeviceUserClient
- Status: … ; creator format: … ; time key: … (units ns?) ; walk cost: …
- Device Utilization % key present? … (fallback for GPU total if IOReport GPUPH is off)
- Needs responsible-PID grouping? (GPU process vs app): …
```

- [ ] **Step 6: Commit**

```bash
git add Spikes FINDINGS.md
git commit -m "spike: per-app GPU time via AGX user clients"
```

---

### Task 7: NetworkStatistics spike (per-app network)

**Files:**
- Create: `Spikes/Sources/CPrivate/include/NStat.h`, `Spikes/Sources/spike-nstat/main.swift`
- Modify: `Spikes/Package.swift` (add target)

**Interfaces:**
- Consumes: `CPrivate`.
- Produces: in `FINDINGS.md`, the description and counts dictionary keys, the remote address key and format, callback threading, and the cost.

- [ ] **Step 1: Write `Spikes/Sources/CPrivate/include/NStat.h`**

```c
#pragma once
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>

// Private NetworkStatistics.framework (what nettop uses). Reverse-engineered; spike validates.
typedef void *NStatManagerRef;
typedef void *NStatSourceRef;

CF_IMPLICIT_BRIDGING_ENABLED
NStatManagerRef NStatManagerCreate(CFAllocatorRef allocator, dispatch_queue_t queue, void (^added)(NStatSourceRef source, void *unknown));
void NStatManagerDestroy(NStatManagerRef mgr);
void NStatManagerAddAllTCP(NStatManagerRef mgr);
void NStatManagerAddAllUDP(NStatManagerRef mgr);
void NStatManagerQueryAllSources(NStatManagerRef mgr, void (^done)(void));
void NStatManagerQueryAllSourcesDescriptions(NStatManagerRef mgr, void (^done)(void));
void NStatSourceSetDescriptionBlock(NStatSourceRef src, void (^block)(CFDictionaryRef description));
void NStatSourceSetCountsBlock(NStatSourceRef src, void (^block)(CFDictionaryRef counts));
void NStatSourceSetRemovedBlock(NStatSourceRef src, void (^block)(void));

extern const CFStringRef kNStatSrcKeyPID;
extern const CFStringRef kNStatSrcKeyProcessName;
extern const CFStringRef kNStatSrcKeyProvider;
extern const CFStringRef kNStatSrcKeyRxBytes;
extern const CFStringRef kNStatSrcKeyTxBytes;
CF_IMPLICIT_BRIDGING_DISABLED
```

- [ ] **Step 2: Add the target to `Spikes/Package.swift`**

```swift
        .executableTarget(name: "spike-nstat", dependencies: ["CPrivate"]),
```

- [ ] **Step 3: Write `Spikes/Sources/spike-nstat/main.swift`**

```swift
import Foundation
import CPrivate

// All state is touched only on `q` (serial). Main thread only sleeps and q.sync-reads.
let q = DispatchQueue(label: "nstat")
struct Src { var pid = 0; var name = "?"; var provider = "?"; var rx: UInt64 = 0; var tx: UInt64 = 0 }
var sources: [UnsafeMutableRawPointer: Src] = [:]
var printedDescKeys = false, printedCountKeys = false, sampleDesc = ""

func u64(_ d: NSDictionary, _ k: CFString) -> UInt64 { (d[k as String] as? NSNumber)?.uint64Value ?? 0 }

guard let mgr = NStatManagerCreate(kCFAllocatorDefault, q, { src, _ in
    guard let src else { return }
    sources[src] = Src()
    NStatSourceSetDescriptionBlock(src) { cf in
        guard let d = cf as NSDictionary? else { return }
        if !printedDescKeys { printedDescKeys = true; print("desc keys:", (d.allKeys as? [String] ?? []).sorted().joined(separator: ", ")); sampleDesc = "\(d)" }
        sources[src]?.pid = (d[kNStatSrcKeyPID as String] as? NSNumber)?.intValue ?? 0
        sources[src]?.name = d[kNStatSrcKeyProcessName as String] as? String ?? "?"
        sources[src]?.provider = d[kNStatSrcKeyProvider as String] as? String ?? "?"
        // Newer OSes may put byte counters in the description too.
        if d[kNStatSrcKeyRxBytes as String] != nil { sources[src]?.rx = u64(d, kNStatSrcKeyRxBytes); sources[src]?.tx = u64(d, kNStatSrcKeyTxBytes) }
    }
    NStatSourceSetCountsBlock(src) { cf in
        guard let d = cf as NSDictionary? else { return }
        if !printedCountKeys { printedCountKeys = true; print("count keys:", (d.allKeys as? [String] ?? []).sorted().joined(separator: ", ")) }
        sources[src]?.rx = u64(d, kNStatSrcKeyRxBytes)
        sources[src]?.tx = u64(d, kNStatSrcKeyTxBytes)
    }
    NStatSourceSetRemovedBlock(src) { sources[src] = nil }
}) else { print("NStatManagerCreate returned NULL"); exit(1) }

NStatManagerAddAllTCP(mgr)
NStatManagerAddAllUDP(mgr)

func perPid() -> [Int: (String, UInt64, UInt64)] {
    q.sync {
        var m: [Int: (String, UInt64, UInt64)] = [:]
        for s in sources.values { var e = m[s.pid, default: (s.name, 0, 0)]; e.1 += s.rx; e.2 += s.tx; m[s.pid] = e }
        return m
    }
}

func query() {
    let g = DispatchGroup()
    g.enter(); NStatManagerQueryAllSourcesDescriptions(mgr) { g.leave() }
    g.enter(); NStatManagerQueryAllSources(mgr) { g.leave() }
    if g.wait(timeout: .now() + 3) == .timedOut { print("query timeout") }
}

let clock = ContinuousClock()
let firstCost = clock.measure { query() }
let a = perPid()
Thread.sleep(forTimeInterval: 2)
let queryCost = clock.measure { query() }
let b = perPid()
print("sources=\(q.sync { sources.count }) pids=\(b.count) firstQuery=\(firstCost) query=\(queryCost)")
print("sample desc:\n" + q.sync { sampleDesc }.split(separator: "\n").prefix(30).joined(separator: "\n"))
let rates = b.map { pid, v -> (String, Double, Double) in
    let o = a[pid] ?? (v.0, v.1, v.2)
    return ("\(v.0) [\(pid)]", Double(v.1 &- o.1) / 2048, Double(v.2 &- o.2) / 2048)  // KB/s over 2 s
}.sorted { $0.1 + $0.2 > $1.1 + $1.2 }
for (n, rx, tx) in rates.prefix(10) {
    print(n.padding(toLength: 40, withPad: " ", startingAt: 0) + String(format: "↓%8.1f KB/s  ↑%8.1f KB/s", rx, tx))
}
NStatManagerDestroy(mgr)
```

- [ ] **Step 4: Build and run with network load**

Run: `cd Spikes && swift build 2>&1 | grep error | head; (curl -s -o /dev/null https://speed.cloudflare.com/__down?bytes=200000000 & P=$!; sleep 1; swift run spike-nstat 2>&1 | head -60; kill $P 2>/dev/null)`
Expected: `curl` is at the top with a large ↓ rate. The printed key lists show the remote address key name (look for `remoteAddress`/`remote…` in `desc keys`).

- [ ] **Step 5: Verify against `nettop`**

Run: `nettop -P -L 2 -J bytes_in,bytes_out -s 2 2>/dev/null | tail -15`
Top talkers and their magnitudes should match.

- [ ] **Step 6: Record in `FINDINGS.md`**

```markdown
## nstat — NetworkStatistics
- Status: … ; desc keys: … ; count keys: … ; remote addr key + type (CFData sockaddr?): …
- Counters in description or counts block? … ; removed-source handling: …
- Query cost: … ; callbacks on provided queue? …
- Accuracy vs nettop: …
```

- [ ] **Step 7: Commit**

```bash
git add Spikes FINDINGS.md
git commit -m "spike: NetworkStatistics per-app bandwidth"
```

---

### Task 8: Consolidate findings + go/no-go

**Files:**
- Modify: `FINDINGS.md` (add summary at top), `SPEC.md` (data sources table only, if findings change it)

- [ ] **Step 1: Add a summary table at the top of `FINDINGS.md`**

```markdown
| Source | Status | Cost/sample | Replaces/needs |
|---|---|---|---|
| proc_pid_rusage | | | |
| libsysmon | | | |
| IOReport | | | |
| HID temps | | | |
| SMC | | | |
| AGX per-app GPU | | | |
| NStat | | | |
```

- [ ] **Step 2: Apply the decision rules**

- libsysmon ❌ **and** EPERM covers notable processes (kernel_task, WindowServer): **stop and ask the user**. The options are (1) accept gaps and label those rows "restricted", or (2) add an `SMAppService` privileged helper, which the spec rejected earlier.
- IOReport ❌: GPU % falls back to AGX `Device Utilization %`. Watts are unavailable, so ask the user whether to drop the Power card.
- HID ❌: temps come from SMC `T…` keys alone.
- NStat ❌: ask the user. The fallback is system totals only, with no per-app network.
- Everything else ✅: proceed to M1.

- [ ] **Step 3: Update the `SPEC.md` data sources table** if any source changed. Leave the rest alone.

- [ ] **Step 4: Estimate the full sampler cost**

Add up the per-source costs from the findings. That total is the cost of one full sample. Check it against the relaxed budget: <1% CPU at a 5s interval means under about 50ms of CPU per sample. Record the result (advisory, not a gate).

- [ ] **Step 5: Commit**

```bash
git add FINDINGS.md SPEC.md
git commit -m "docs: M0 findings and go/no-go"
```

---

## Roadmap after M0 (each milestone gets its own plan, written after M0 findings)

The interfaces below are sketches. M1's plan finalizes them using the findings.

- **M1: App shell + CPU/memory + grouping.**
  - Xcode app target `SystemMonitor` plus local package `MonitorCore`.
  - `protocol Sensor { associatedtype Reading: Sendable; func sample() throws -> Reading }`
  - `ProcessSampler` (proc_pid_rusage)
  - `AppGrouper` (responsible PID → `AppKey { bundleID?, name, path }`)
  - `RateCalculator` (counter deltas, pure, TDD with fixtures)
  - `NSStatusItem` + `NSPopover` hosting SwiftUI `CardStack`
  - CPU and Memory cards with top 3 apps and a 60s ring-buffer sparkline
  - `SamplerLoop` with an adaptive 5s/1s interval
  - `SMAppService.mainApp` launch at login
- **M2: libsysmon backend.** `SysmonProcessSampler` conforms to the same protocol as `ProcessSampler`, with automatic fallback. Adds a Disk card (per-app bytes/s, volume free space) and per-app energy.
- **M3: Hardware.** `IOReportSensor` (cluster residency, GPU %, watts), `HIDTempSensor` plus a curated mapping, `SMCSensor` (fans, cached key list), battery via IOPowerSources. Adds GPU, Temps, Power, and Fans cards. Per-app GPU via AGX.
- **M4: Network.** `NStatSensor` (long-lived manager, per-app rates, removed-source accounting), system totals via `getifaddrs`, Network card, live connection model with reverse-DNS cache.
- **M5: Store + dashboard.**
  - GRDB schema: `system_sample`, `app_sample`, `app` dictionary table; rollup tables `*_1m` and `*_15m`
  - batched writer (30–60s), rollup/retention job
  - dashboard window: Swift Charts timeline with scrubbing, and a squarified treemap bound to the scrub time
- **M6: Per-app page + actions.** App detail view (all metric charts, process list, live connections), context menu with Quit (`NSRunningApplication.terminate`), Force Quit (confirm, `forceTerminate`/`kill`), Reveal, and Open in Activity Monitor. Card reorder/hide is persisted.
