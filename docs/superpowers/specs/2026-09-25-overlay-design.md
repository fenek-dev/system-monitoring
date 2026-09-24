# Telltale — On-screen stats overlay (design)

Date: 2026-09-25. Status: approved design (approach A), pending spec review.

## Goal
Show CPU, GPU and memory permanently on screen, like the NVIDIA overlay. A global key combination toggles it (default ⌥Z).

## Decisions (from the brainstorm)
| Topic | Decision |
|---|---|
| Content | One compact block: CPU %, GPU %, memory used; below each, the min / max / avg over the last 60 s |
| Placement | Fixed corner. Default top-right, 8 pt below the menu bar, 8 pt from the screen edge. Click-through. Every Space, above full-screen apps |
| Display | The display under the mouse pointer, re-checked every tick. It moves when the pointer changes display |
| Persistence | On/off, corner, opacity and hotkey are persisted. If it was on at quit, it's on after relaunch or login |
| Sampling | Approach A: a new `overlay` mode. Totals every 1 s; everything else on its background cadence (5 s) |
| Stats window | Rolling last 60 s, never reset |
| Out of scope | FPS (no public macOS API), dragging, multi-display copies, per-app rows, a separate reset hotkey |

## UI
```
┌──────────────────────────────────────────────┐
│ CPU 34%        GPU 12%        MEM 15.2 GB     │
│ ↓8 ↑91 ø22     ↓0 ↑67 ø9      ↓14.8 ↑16.1 ø15.3│
└──────────────────────────────────────────────┘
```
- Row 1: label in the category colour (`TTColor.cpu`, `.gpu`, `.mem`, `TTFont.captionMedium`), value in `textPrimary` using the tabular value font. Formats follow DESIGN §5: CPU/GPU `TTFormat.cpuPercent` rounded to 0 digits; memory `TTFormat.memory(.headline)`.
- Row 2: `micro` in `textSecondary`, "↓min ↑max øavg". Memory figures are shown without the unit.
- MEM value colour follows memory pressure (ICR-12 thresholds): warning → `statusElevated`, critical → `statusCritical`.
- Unavailable metric: "—" in `textTertiary` for the value and "— — —" for the stats row. No tooltip, since the overlay is click-through.
- Fewer than 2 samples in the window: the stats row shows "—".
- Background: `bgElevated` at the opacity setting (default 0.85, range 0.4–1.0), radius 8, padding 8×6, a 1-pt `separator` stroke. Dark appearance always.
- No animation. Values change in place.

## Stats (min / max / avg)
- Source: `LiveModel`'s 1-s grid series (`chartSeries`) for `.cpuTotal`, `.gpuTotal`, `.memUsed` over [now − 60 s, now].
- min and max are taken over the non-nil samples. avg is time-weighted over the non-nil samples; gaps are excluded and never count as 0.
- Pure function `OverlayStats.compute(points:window:now:) -> (min, max, avg)?`, unit-tested: gaps, pause, a single sample, the move from a 5-s to a 1-s cadence, and nil samples.
- Recomputed once per tick, not per render.

## Window (App target)
- `OverlayPanelController` owns an `NSPanel`:
  - style `[.borderless, .nonactivatingPanel]`
  - `level = .statusBar`
  - `ignoresMouseEvents = true`
  - `hasShadow = false`, `isOpaque = false`, `backgroundColor = .clear`
  - `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`
  - never becomes key or main
- Content is an `NSHostingView` of `OverlayView` (MonitorScreens), sized to fit.
- Placement: pure `OverlayPlacement.frame(content:screen:corner:) -> NSRect`, based on `screen.visibleFrame` with an 8-pt inset. Tests cover all four corners, a notch or menu-bar inset, and a secondary display with a negative origin.
- Display choice: `NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? .main`, evaluated on each tick while visible. The panel moves only when the display changes.
- The panel is re-placed on screen-parameter changes.
- The hosting view is torn down when the overlay is hidden, as the popover and dashboard already do.

## Hotkey
- `GlobalHotKey` in App wraps Carbon `RegisterEventHotKey` / `InstallEventHandler`. It needs no Accessibility permission.
- Default: ⌥Z (keyCode `kVK_ANSI_Z`, `optionKey`). Stored as `{keyCode, carbonModifiers}` in `SettingsStore`.
- If registration fails (for example because another app owns the combination), Settings shows "Shortcut unavailable — in use by another app", and the overlay can still be toggled from the popover footer.
- Settings › General gets:
  - an "Overlay" toggle
  - an "Overlay shortcut" recorder that captures the next key + modifier combination; at least one of ⌘⌥⌃ is required; Esc cancels
  - a corner picker (four options)
  - an opacity slider
- A note under the recorder: "⌥Z blocks typing Ω."
- Pressing the hotkey toggles the overlay and persists the new state.
- The popover footer gets an "Overlay" toggle item (⌥Z hint), so the overlay stays reachable without the hotkey.

## Sampling (overlay mode)
- `SamplingMode` gains `.overlay` with interval 1 s.
- `UIVisibility` gains `overlayVisible: Bool`. Mode resolution:
  - `interactive` if the popover or dashboard is open
  - else `overlay` if the overlay is visible
  - else `background`
  - `paused` still wins
- `SensorCadence` gains `overlay: Duration?`, defaulting to nil, which means "use `background`".
- Sensors that feed CPU, GPU and memory totals set `overlay: .zero` (every tick):
  - host CPU ticks (total)
  - IOReport SoC (GPU %)
  - host memory statistics, including pressure
- Everything else keeps its background cadence: the process table, rusage, coalitions, NStat, SMC, HID, battery, disk, volumes, ps RSS, latency, Wi-Fi.
- The engine assembles a frame every overlay tick using cached readings for the slower sensors (the existing cached-tick path). Rates of slow sensors must not be recomputed from cached readings (the existing guard).
- Store: in overlay mode, only ticks on which the process sensors ran (5-s ticks) are recorded, so history volume matches background mode. A unit test checks the record count over 10 s.
- The alert state machine and status icon are unchanged.
- LiveModel: in overlay mode it publishes only the categories the overlay reads (cpu, gpu, memory) plus the series. The other categories update at 5 s, as in background.

## State and settings
- `SettingsStore` gains:
  - `overlayEnabled: Bool` (false)
  - `overlayCorner: .topRight` (enum of four)
  - `overlayOpacity: 0.85`
  - `overlayHotKey: {keyCode: kVK_ANSI_Z, modifiers: optionKey}`
- Launch: if `overlayEnabled`, show the overlay after the first frame, and show "—" until data arrives.
- Quit: the state stays as it was.

## Performance budget (advisory)
- Overlay on, UI otherwise closed: target ≤ 2% of one core average and ≤ 30 MB footprint. Measure with `scripts/perf.sh`, adding an overlay-on scenario, in Release, 2 min.
- Overlay per-tick work: one `OverlayStats` compute for each of 3 series of ≤ 60 points, plus one SwiftUI update of 6 texts.

## Testing
- Unit tests:
  - `OverlayStats`
  - `OverlayPlacement`
  - display choice (pure function over screen frames plus a mouse point)
  - mode resolution truth table
  - cadence selection in overlay mode (which sensors run on which ticks)
  - store recording cadence in overlay mode
  - `SettingsStore` persistence
  - hotkey recorder validation (modifier required, Esc cancels)
- Snapshot goldens, strict mode, en_US/London:
  - `overlay-calm`
  - `overlay-memoryWarning`
  - `overlay-memoryCritical`
  - `overlay-unavailable` (GPU "—")
  - `overlay-collecting` (stats "—")
  - Settings with the overlay section
- Manual: the hotkey toggles the overlay system-wide and over a full-screen app; the panel follows the pointer across displays; clicks pass through.

## Files (expected)
- `MonitorModel`: `SamplingMode.overlay`, `UIVisibility.overlayVisible`, `SensorCadence.overlay`, settings keys.
- `MonitorEngine`: mode and cadence resolution; overlay-mode record gating.
- `MonitorSensors`: `overlay: .zero` on the three total sensors.
- `MonitorLive`: overlay-mode category publishing.
- `MonitorScreens`: `Overlay/OverlayView.swift`, `OverlayStats.swift`, `OverlayPlacement.swift`, Settings section, popover footer item.
- `App`: `Overlay/OverlayPanelController.swift`, `HotKey/GlobalHotKey.swift`, AppDelegate wiring, visibility input.
- `docs`: DESIGN.md gets a new §3.16 "Overlay"; ARCHITECTURE gets ICR-16 (overlay mode, cadence field, visibility input).
