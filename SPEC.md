# System Monitor — Spec

Native macOS menu bar system monitor (iStat Menus–like) with per-app attribution and history dashboard.

## Target
- Personal use, direct build, **no sandbox**, no App Store.
- Apple Silicon only (M1+). macOS 14+ (dev machine: macOS 26.5, Xcode 26.6, Swift 6.3).

## Stack
- Pure Swift. SwiftUI + AppKit (`NSStatusItem`, `NSPopover`/panel).
- Swift Charts for graphs. GRDB (SQLite, WAL) for history.
- Private/undocumented APIs allowed, each behind a `Sensor` adapter. A broken source shows "unavailable" and the app keeps running.

## Categories
CPU (total + P/E clusters), GPU, Memory, Network, Temperatures, Power/Energy, Disk I/O + storage, Fans.

## Data sources
| Metric | Source | Per-app |
|---|---|---|
| Process table (CPU time, mem, disk I/O, energy) | `libsysmon` (sysmond, private) → fallback `proc_pid_rusage`/`proc_pidinfo` | yes |
| CPU total / per-core | `host_processor_info` | – |
| P/E cluster usage & freq, GPU %, CPU/GPU/ANE/DRAM watts | IOReport (private) | – |
| Per-app GPU time | IORegistry `AGXDeviceUserClient` (`accumulatedGPUTime`) | yes |
| Memory pressure, swap, compressed | `host_statistics64`, `sysctl vm.swapusage`, memorystatus | – |
| Network per-app + connections | `NetworkStatistics.framework` (private) | yes |
| System network totals | `getifaddrs` / `sysctl` | – |
| Temps | `IOHIDEventSystemClient` sensors (private) | – |
| Thermal state | `ProcessInfo.thermalState` | – |
| Fans | SMC (`AppleSMC` user client) | – |
| Battery | IOKit `AppleSmartBattery` / IOPowerSources | – |
| Storage | `URLResourceValues` volume capacity | – |

## Attribution
- Processes grouped into **apps** via responsible PID (`responsibility_get_pid_responsible_for_pid`, private). Fallback: bundle path of executable.
- Non-app daemons are grouped under "System". Each app row expands into its processes.

## Menu bar & popover
- One **static** icon. No live values in the bar.
- Popover: scrollable stacked **cards**, one per category: headline value, 60s sparkline, top 3 apps. Cards can be reordered and hidden (persisted in UserDefaults).
- Footer: "Open Dashboard".

## Dashboard window
- **System timeline**: per-category line charts of system totals over a selectable range (1h / 24h / 7d / 90d).
- **Time-travel treemap**: app share of the selected metric. Live by default. Scrubbing the timeline shows shares at that moment.
- **Per-app detail page**: all metrics over time, process list, live network connections (remote host via reverse DNS, port, protocol, rate).
- **Temps**: curated groups (CPU P/E die max/avg, GPU, SSD, battery), thermal state, and an expandable raw sensor list with history.

## Actions
Right-click an app row: Quit, Force Quit (confirm), Reveal in Finder, Open in Activity Monitor. Only the current user's processes.

## Sampling & storage
- Always-on background sampler. Every **5s** with the UI closed, **1s** while the popover or dashboard is open.
- Per sample, store apps above a small threshold on any metric (e.g. >0.5% CPU, >1 KB/s net, any GPU, >100 KB/s disk). The rest is summed into an `other` row.
- System totals are stored every sample.
- Batched inserts every 30–60s. Rollups: full resolution for 24h, 1-min buckets for 7d, 15-min buckets for 90d. Target DB <200 MB.
- Network connections are live only (not persisted).

## Extras (v1)
- Launch at login (`SMAppService.mainApp`).
- Out of scope for v1: alerts, global hotkey, export, configurable rates/retention, Intel, App Store.

## Budget (advisory)
UI closed: <1% avg CPU of one core, <80 MB RSS.

## Structure
```
system-monitor/
  App/                 Xcode app target (UI only)
  MonitorCore/         SwiftPM package
    Sensors/           Sensor protocol + adapters (one per source)
    Aggregator/        PID→app grouping, counter deltas → rates
    Store/             GRDB schema, batched writer, rollups
  Spikes/              M0 CLI spikes (throwaway)
```
Core logic is tested with `swift test` against recorded fixture samples. Sensors get smoke tests on the real machine.

## Milestones
- **M0** CLI spikes on macOS 26: libsysmon, IOReport, HID temps, SMC fans, NStat, AGX per-app GPU, responsible PID.
- **M1** App shell: status item, popover cards, CPU + memory, app grouping, launch at login.
- **M2** libsysmon backend (root procs), per-app disk + energy.
- **M3** IOReport (GPU, clusters, watts), temps, fans, battery.
- **M4** Network (NStat), live connections.
- **M5** Store + rollups, dashboard timeline, time-travel treemap.
- **M6** Per-app detail page, Quit/Force Quit/Reveal.
