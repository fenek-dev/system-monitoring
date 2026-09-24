# Telltale — Spec

Native macOS menu bar system monitor (iStat Menus–like) with per-app attribution and history dashboard.

## Design reference (binding for look & layout)
Claude Design canvas "Telltale — macOS system monitor": https://claude.ai/artifact/CobFLbd5RJ3Eoq3HLYpSKJ
Local copy: `docs/design/artboards/*.dc.html` (13 artboards: MenuBar, MenuBarAlert, StatusIcon, Main=Overview, CPU, GPU, Memory, Network, Thermals, Power, Disk, Processes, History). Tokens/components: `docs/design/DESIGN.md`.
The design wins on look, layout, copy and screen set. Where this spec and the design differ, the rulings below apply. Anything else in this spec that the design doesn't show still gets built, in the design's visual language.

### Rulings (2026-09-24)
- **Adopted from the design:**
  - Screens: status icon states (calm, elevated, critical), popover with the thermal/pressure alert banner, per-category dashboard pages, Processes page, History page with event markers, device header, Pause sampling, Export CSV (History range), Settings button.
  - History: ranges Live / 1H / 24H / 7D / 30D, retention 30 days. This replaces the earlier 90 days.
  - Alerts: built-in states only (thermal pressure ≥ fair, memory pressure warn/critical, runaway app). Shown as a popover banner and the icon state. No custom rules, no Notification Center.
- **Spec features the design lacks. Build them in the design's style:**
  - Popover rows expand to the top 3 apps for that category.
  - Time-travel treemap on History: scrubbing shows app shares at that moment.
  - App grouping: Processes page toggles Apps/Processes. Apps are grouped by responsible PID and expand to their processes.
  - Per-app detail: the Processes inspector grows into an app detail with per-app charts and live connections.
  - Row actions menu: Quit, Force Quit (confirm), Reveal in Finder, Open in Activity Monitor. Disabled on processes owned by root or other users.
  - "Quit Telltale" in the popover.
  - Settings window: launch at login, units.
  - "—" plus a tooltip for any unavailable sensor.
  - Empty and collecting states.
- **Dropped or changed because the data is unavailable or needs root:**
  - Fan Automatic/Full speed control: fans are read-only.
  - Public IP: dropped for privacy, since it needs an outside service.
  - Wi-Fi SSID: dropped (needs Location). Band, channel, RSSI and link rate are kept.
  - Per-app GPU memory: dropped.
  - Renderer column: dropped.
  - App Nap column: dropped.
  - ANE shows watts only, no %.
  - Media engine % is kept only if IOReport exposes it.
  - Energy impact is shown as average watts, not Apple's score. Own-user processes use `RUSAGE_INFO_V6` `ri_energy_nj`; other users' processes get their resource-coalition energy residual; an IOReport SoC-power share is the fallback only when v6 energy is unavailable. (`ri_billed_energy` always reads 0 and is not used.)
  - Per-app Compressed/Private/Ports columns are removed (libsysmon is unusable: sysmond requires an Apple-only entitlement).
  - Root/other-user processes (EPERM for `proc_pid_rusage`): listed from `sysctl KERN_PROC_ALL`; CPU, energy and disk come from resource coalitions (residual per coalition, shown as estimated); memory comes from `/bin/ps` RSS, run only while a process table is open or a memory alert is active; otherwise "—" plus a tooltip.
  - SSD health: only what the NVMe SMART IOKit plugin gives without root, else a status only.
  - Latency and packet loss: unprivileged ICMP (`SOCK_DGRAM`) to the router every 10s.
  - Disk IOPS: from IOBlockStorageDriver `Statistics`.
  - Preventing sleep: `IOPMCopyAssertionsByProcess`.
- **Appearance:** the app UI is dark, matching the design. The menu bar glyph is a template image, with tinted variants for the elevated and critical states.

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
| Process list | `sysctl KERN_PROC_ALL` (all pids incl. root) | yes |
| Per-process CPU time, footprint, disk I/O, energy (own user) | `proc_pid_rusage` `RUSAGE_INFO_V6` (`ri_energy_nj`) + `proc_pidinfo` | yes |
| Root/other-user CPU, energy, disk | resource coalitions (`coalition_info_resource_usage`, private) + `PROC_PIDCOALITIONINFO`; only for coalitions with a restricted member (coalition `gpu_time` unused: unknown unit) | yes (coalition residual) |
| Root/other-user memory | `/bin/ps -axo pid,rss` (setuid), on demand | yes |
| CPU total / per-core | `host_processor_info` | – |
| P/E cluster usage & freq, GPU %, CPU/GPU/ANE/DRAM watts | IOReport (private) | – |
| Per-app GPU time | IORegistry `AGXDeviceUserClient` (`accumulatedGPUTime`) | yes |
| Memory pressure, swap, compressed | `host_statistics64`, `sysctl vm.swapusage`, memorystatus | – |
| Network per-app + connections | `NetworkStatistics.framework` (private) | yes |
| System network totals | `getifaddrs` / `sysctl` | – |
| Temps (curated P/E/GPU/SoC groups) | SMC `T*` key families (mapping per `hw.model`) | – |
| Temps (raw list, Thermals page only) | `IOHIDEventSystemClient` sensors (private) | – |
| Thermal state | `ProcessInfo.thermalState` | – |
| Fans | SMC (`AppleSMC` user client) | – |
| Battery | IOKit `AppleSmartBattery` / IOPowerSources | – |
| Storage | `URLResourceValues` volume capacity | – |

## Attribution
- Processes grouped into **apps** via responsible PID (`responsibility_get_pid_responsible_for_pid`, private). The app is the outermost `.app` bundle of the responsible process's executable.
- User-owned executables outside an app bundle (e.g. `node`, Homebrew services) get their own group. Root/other-user daemons outside a bundle are grouped under "System". Each app row expands into its processes.
- Processes owned by other users (EPERM): CPU/energy/disk come from the resource-coalition residual. If a coalition has exactly one such process, it gets the residual (shown as estimated). Otherwise the residual is one row per coalition, named after the coalition leader, in the leader's app ("System" if there is no leader). GPU for all processes comes from AGX. Details: `docs/ARCHITECTURE.md` §3, §5.5–5.6.

## Menu bar & popover
- One icon, no live values in the bar; it shows status states (calm/elevated/critical) per the design.
- Popover: design's row list, one row per category (headline value, 60s sparkline), each row expandable to its top 3 apps. Rows reorderable/hideable in Settings (persisted in UserDefaults).
- Footer: "Open Dashboard".

## Dashboard window
- **System timeline**: per-category line charts of system totals over a selectable range (Live / 1H / 24H / 7D / 30D).
- **Time-travel treemap**: app share of the selected metric. Live by default. Scrubbing the timeline shows shares at that moment.
- **Per-app detail page**: all metrics over time, process list, live network connections (remote host via reverse DNS, port, protocol, rate).
- **Temps**: curated groups (CPU P/E die max/avg, GPU, SSD, battery), thermal state, and an expandable raw sensor list with history.

## Actions
Right-click an app row: Quit, Force Quit (confirm), Reveal in Finder, Open in Activity Monitor. Only the current user's processes.

## Sampling & storage
- Always-on background sampler. Every **5s** with the UI closed, **1s** while the popover or dashboard is open.
- Per sample, store apps above a small threshold on any metric (e.g. >0.5% CPU, >1 KB/s net, any GPU, >100 KB/s disk). The rest is summed into an `other` row.
- System totals are stored every sample.
- Batched inserts every 30–60s. Rollups: full resolution for 24h, 1-min buckets for 7d, 15-min buckets for 30d. Target DB <200 MB.
- While sampling is paused (user action), nothing is recorded. The gap shows as a break in the charts.
- Network connections are live only (not persisted).

## Extras (v1)
- Launch at login (`SMAppService.mainApp`).
- Out of scope for v1: custom alert rules, Notification Center, global hotkey, configurable rates/retention, Intel, App Store. (Built-in alert states and CSV export are in scope — see Rulings.)

## Budget (advisory)
UI closed: <1% avg CPU of one core, <80 MB RSS.

## Structure
See `docs/ARCHITECTURE.md` (binding module layout, interfaces, concurrency) and `docs/superpowers/plans/2026-09-24-parallel-build-plan.md` (workstreams). Milestones below are superseded by the parallel build plan's checkpoints CP0–CP5.

## Milestones
- **M0** CLI spikes on macOS 26: libsysmon (unusable), resource coalitions, IOReport, HID temps, SMC fans, NStat, AGX per-app GPU, responsible PID.
- **M1** App shell: status item, popover cards, CPU + memory, app grouping, launch at login.
- **M2** Root processes via resource coalitions + `ps` RSS, per-app disk + energy (rusage v6).
- **M3** IOReport (GPU, clusters, watts), temps, fans, battery.
- **M4** Network (NStat), live connections.
- **M5** Store + rollups, dashboard timeline, time-travel treemap.
- **M6** Per-app detail page, Quit/Force Quit/Reveal.
