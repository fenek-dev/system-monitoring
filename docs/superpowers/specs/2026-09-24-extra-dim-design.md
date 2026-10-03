# Extra Dim (below minimum brightness) — design

Date: 2026-09-24 · Status: approved design, pre-plan

## 1. Goal

Let the built-in display go darker than macOS's minimum backlight. Once the backlight is at the system minimum, further presses of the brightness-down key dim the picture in software through the display gamma table, in 8 perceptual steps down to 10 % luminance. Brightness-up undoes the extra dim first, then hands control back to the system.

Non-goals: external displays, DDC/CI, overlay-window dimming, hotkeys other than the brightness keys, a popover slider or indicator, a configurable step count or floor, persisting the dim level across relaunches, coexisting with other gamma apps (f.lux, Lunar, calibration tools).

## 2. Decisions

| Topic | Decision |
|---|---|
| Displays | Built-in only. No built-in display (clamshell) → feature inert |
| Control | Brightness keys. At system min, brightness-down adds a dim step. Brightness-up removes steps before passing through to the system |
| Mechanism | Gamma table (`CGSetDisplayTransferByTable`), because screenshots and screen recordings must stay normal. The overlay window is rejected: it shows in captures |
| Accepted side effects | Cursor dims too. Other gamma apps conflict (the fight guard gives up, §5.5) |
| Steps / floor | 8 steps, floor 10 % luminance |
| Curve | Perceptual: geometric in luminance (§4) |
| Persistence | The level survives sleep, display sleep, lock and display reconfiguration. It resets on quit, crash and relaunch. The level is never written to disk |
| Feedback | Telltale HUD in the Telltale dark panel style (`bgPopover`, `shadowPopover`) |
| Enablement | Settings toggle, off by default. Turning it on requests Accessibility |
| System brightness raised elsewhere (Control Center, auto-brightness) | Extra dim cleared. It only exists at system min |

## 3. Architecture

### Layering

| Unit | Location | Kind | Job |
|---|---|---|---|
| `ExtraDimMachine` | new target `MonitorExtraDim` (no dependencies) | pure value type | State + transitions: inputs → `(consumeKey, [Action])` |
| `ExtraDimCurve` | `MonitorExtraDim` | pure | Level → luminance → table multiplier |
| `GammaTable` | `MonitorExtraDim` | pure | Base-table capture value type, scaling, drift comparison |
| `DisplayServices.h` | `CPrivate/include` | C header, weak | `DisplayServicesGetBrightness` + `tt_displayservices_available()` |
| `TTExtraDimHUD` | `MonitorUIKit` | SwiftUI view | HUD content from tokens |
| `SettingsStore.extraDimEnabled` + Settings row | `MonitorScreens/Shell` | settings | Toggle + permission status line |
| `BrightnessKeyTap` | `App/Sources/Services/ExtraDim/` | AppKit adapter | Active `CGEventTap` for brightness keys |
| `GammaDimmer` | same | adapter | Capture / apply / restore the built-in display gamma |
| `BuiltinDisplay` | same | adapter | Resolve the built-in `CGDirectDisplayID`, read brightness |
| `DisplayEvents` | same | adapter | Wake / screens-wake / screen-params / unlock notifications |
| `ExtraDimHUDPanel` | same | adapter | Borderless non-activating `NSPanel` that hosts `TTExtraDimHUD` |
| `ExtraDimService` | same | glue, `@MainActor` | Owns the machine, runs its actions, owns the watchdog timer |

The machine never touches AppKit, CoreGraphics or time. The service feeds it inputs, including `now` for the fight guard, and executes its actions.

### Machine

State: `enabled: Bool`, `level: Int` (0…8), `driftTimes: [Date]` (fight guard window).

Inputs:
- `.setEnabled(Bool)`
- `.key(.down | .up, brightness: Float?)`: brightness is read inside the tap callback. `nil` means the read failed
- `.brightness(Float?)`: watchdog tick
- `.gammaDrift(at: Date)`: the watchdog found the live table ≠ expected
- `.reapply`: wake, screens-wake, unlock, screen params changed with the built-in display still present
- `.builtinDisplayGone`

Actions: `.captureBase`, `.applyGamma(level:)`, `.restoreGamma`, `.showHUD(.level(Int) | .resetByOtherApp | .cannotDim)`, `.startWatchdog`, `.stopWatchdog`.

"At min" = `brightness != nil && brightness <= 1/16 + 0.005`: the lowest visible key step. On MacBook Pros the next system step (0) turns the backlight off, so extra dim takes over brightness-down at 1/16 and the system never reaches 0 while the feature is on.

Stale-dim rule: any `.key` or `.brightness` input that finds brightness readable and above min while level > 0 first clears (`restoreGamma`, level 0, `stopWatchdog`). The input is then handled as at level 0, so it passes through.

### Private API

`CPrivate/include/DisplayServices.h`:
```c
extern int DisplayServicesGetBrightness(CGDirectDisplayID display, float *brightness) __attribute__((weak_import));
static inline bool tt_displayservices_available(void) { return &DisplayServicesGetBrightness != NULL; }
```
`privateLinks` gains `-weak_framework DisplayServices` (already under `-F/System/Library/PrivateFrameworks`). Return value 0 = success.

## 4. Dim curve

Luminance factor per level `n` (0…8): `L(n) = 0.10^(n/8)`, a constant ≈ 25 % luminance drop per step.
Gamma tables work in display-encoded space, so the table multiplier is `m(n) = L(n)^(1/2.2)`.

| n | 0 | 1 | 2 | 4 | 6 | 8 |
|---|---|---|---|---|---|---|
| L | 1.000 | 0.750 | 0.562 | 0.316 | 0.178 | 0.100 |
| m | 1.000 | 0.878 | 0.770 | 0.592 | 0.456 | 0.351 |

Applied table = captured base table × `m(n)`, per channel, per entry. Scaling the captured base (not writing a formula) keeps any ICC calibration. Night Shift and True Tone are applied outside the gamma table and are unaffected.

## 5. Data flow

### 5.1 Threading

The tap's run loop source is on the main run loop, so the callback runs on MainActor. The callback does only a brightness read and a machine step, then returns consume/pass. Gamma and HUD actions are enqueued to run after the callback returns (`DispatchQueue.main.async`), which keeps the tap well under its timeout.

### 5.2 Brightness-down (key code 3, key-down only)

| Condition | Consume | Actions |
|---|---|---|
| Disabled, or brightness above min or unreadable | no | — |
| At min, level 0 | yes | `captureBase`, `applyGamma(1)`, `showHUD(1)`, `startWatchdog` |
| At min, level 1–7 | yes | `applyGamma(n+1)`, `showHUD(n+1)` |
| At min, level 8 | yes | `showHUD(8)` |

### 5.3 Brightness-up (key code 2, key-down only)

| Condition | Consume | Actions |
|---|---|---|
| Disabled, or level 0 | no | — |
| Level 2–8 | yes | `applyGamma(n-1)`, `showHUD(n-1)` |
| Level 1 | yes | `restoreGamma`, `showHUD(0)`, `stopWatchdog` |

Key-up events: `BrightnessKeyTap` remembers whether it consumed the last key-down for each key code and treats the matching key-up the same way, so the system never sees half a press. This is adapter state, not machine state. Auto-repeat key-downs are handled like normal key-downs.

### 5.4 Re-apply

When level > 0 on `NSWorkspace.didWakeNotification`, `screensDidWakeNotification`, distributed `com.apple.screenIsUnlocked`, or `NSApplication.didChangeScreenParametersNotification`:
- Built-in display missing → `.builtinDisplayGone`: `restoreGamma`, level 0, drop the base, `stopWatchdog`.
- Otherwise `.reapply`: `applyGamma(level)` from the stored base. The base is captured only at the 0→1 transition, never mid-session, so the dim never compounds.

Apply is idempotent: it always writes `base × m(level)`.

### 5.5 Watchdog (1 s timer, only while level > 0)

1. Read brightness. Above min → `restoreGamma`, level 0, `stopWatchdog` (no HUD). Unreadable → skip this tick.
2. Read the live table and compare it to `base × m(level)`. Any entry differs by more than 1/512 → `.gammaDrift(now)` → `applyGamma(level)`.
3. Fight guard: a 4th drift within 10 s → `restoreGamma`, level 0, `stopWatchdog`, `showHUD(.resetByOtherApp)`, log a notice.

### 5.6 Clear paths

All restore gamma and stop the watchdog: toggle off, `applicationWillTerminate`, built-in display gone, brightness raised above min, fight guard. A crash or `kill -9` needs no handler: Quartz restores ColorSync gamma when the owning process exits.

### 5.7 Enablement and permission

- Toggle on → `AXIsProcessTrustedWithOptions([prompt: true])`. Trusted → create the tap. Not trusted → no tap; the Settings row shows "Needs Accessibility · Open System Settings" (deep link to Privacy & Security › Accessibility).
- There is no trust-change notification: while the Settings window is open and the toggle is on without a tap, poll `AXIsProcessTrusted()` every 1 s and create the tap once it becomes true.
- At launch with the toggle on and trust present → create the tap silently. Toggle on without trust → status line only, no prompt at launch.
- Toggle off → `.setEnabled(false)` (clears the dim) and remove the tap.
- Settings gets the permission state and the "open settings" action from the app through closures, like `reenableCrashedSensors` (nil in renders).

## 6. HUD

- `TTExtraDimHUD` (MonitorUIKit):
  - Sun glyph (SF Symbol `sun.min`), then a row of 8 segments. Filled = active dim steps, drawn in `textPrimary` on `fillTrack`.
  - Label "Extra dim" + "n/8". Variants: `.resetByOtherApp` ("Dimming reset by another app") and `.cannotDim` ("Can't dim this display").
  - Background `bgPopover`, 1-pt card border, card radius, `shadowPopover`, padding 16.
- `ExtraDimHUDPanel`:
  - Borderless, non-activating, `ignoresMouseEvents`, level `.statusBar`, joins all Spaces, full-screen auxiliary.
  - Placed centered horizontally in the lower third of the built-in screen.
  - Shows on each action and fades out 1.2 s after the last one.
  - The hosting view is released when hidden.
- The HUD is under the gamma too, so it dims with the screen. Expected.

## 7. Failure handling

| Failure | Behavior |
|---|---|
| `tt_displayservices_available()` false | Feature unavailable: toggle disabled, tooltip "Not supported on this macOS" |
| `DisplayServicesGetBrightness` error | Treated as "not at min": keys pass through. Logged once per session |
| `CGGetDisplayTransferByTable` / `CGSetDisplayTransferByTable` error | Stay at or return to level 0, `showHUD(.cannotDim)`, log |
| Tap creation fails with trust granted | Settings shows "Keyboard hook failed". Retried on the next toggle-on |
| `tapDisabledByTimeout` / `tapDisabledByUserInput` | Re-enable immediately. More than 3 in 60 s → log a warning, keep re-enabling |
| Trust revoked while running | The tap goes silent. The dim persists until a watchdog clear or quit. Settings shows the status. Accepted |
| Other gamma app | Fight guard (§5.5) |

## 8. Testing

**Unit (`MonitorExtraDimTests`, table-driven over the machine):**
- Down at min, levels 0→8 (actions + consume per step).
- Down at level 8 re-shows the HUD only.
- Up 3→0, then the next up passes through.
- Every key passes through when above min or unreadable.
- Stale dim: level 3 + down key with brightness above min → clear + pass through; same for the up key.
- Disabled machine: every key passes through.
- Watchdog brightness above min clears.
- `.reapply` at level n emits `applyGamma(n)` and no `captureBase`.
- `.builtinDisplayGone` clears.
- Fight guard: 3 drifts in 10 s → re-apply only; the 4th → reset + HUD. Drifts outside the window don't count.
- `.setEnabled(false)` at level > 0 clears.

**Curve:** `m(0) == 1`; `m(8) ≈ 0.351 ± 0.001`; strictly decreasing; `L(n+1)/L(n)` constant.

**`GammaTable`:** scaling preserves the per-entry ratios of the base; drift ε accepts ±1/1024 and rejects 1/256.

**Snapshot (`MonitorSnapshotTesting`):** `TTExtraDimHUD` at levels 0, 4, 8, plus `.resetByOtherApp` and `.cannotDim`.

**Probe:** `telltale-probe brightness` prints DisplayServices availability, the built-in display ID, the current brightness and the gamma table capacity and size. Run it first to confirm the private API on this machine before building any UI.

**Manual checklist (hardware):**
1. Toggle on → Accessibility prompt. Grant → tap is live without a relaunch.
2. At system min: 8 down presses step darker, a 9th changes nothing, the system HUD never appears.
3. Up presses step back, then the system backlight rises.
4. Screenshot (⇧⌘3) and a screen recording while dimmed look normal.
5. System sleep → wake, display sleep → wake, lock → unlock: same level, no lasting flash.
6. Control Center slider raised while dimmed → extra dim clears.
7. Close the lid on an external display → gamma restored. Reopen → level 0.
8. Quit Telltale while dimmed → normal. `kill -9` while dimmed → normal.
9. Run f.lux while dimmed → fight guard resets within ~4 s with the HUD notice.
10. Toggle off while dimmed → normal immediately.
