# M0 Findings — SMC (M1 Max, macOS 26.5)

## smc — AppleSMC (fans + temperature keys)
- Status: done. `smc_open`/`smc_read`/`smc_key_at`/`smc_close` work as specified; build + run clean (`swift build --scratch-path .build-smc`, `swift run --scratch-path .build-smc spike-smc`).
- Fans: 2 (`FNum`=2). RPM type: `flt ` (Float32) for `F0Ac`/`F1Ac`/`Mn`/`Mx`/`Tg`, matches the brief.
  - Range: F0 Mn=1200 Mx=5779; F1 Mn=1200 Mx=6241.
  - Idle-ish sample (other spikes/background load present, see caveat below): F0 Ac≈2309–2314, F1 Ac≈2493–2521 — i.e. well above `Mn`, not at the floor. Either this machine never truly idles to `Mn` under normal desktop use, or some background load was already present when "idle" was sampled.
  - Under load (see below): F0 Ac rose to ≈2577–2775, F1 Ac rose to ≈2796–2995 — fans do respond upward monotonically with load, confirming `F#Ac` is live telemetry, not a static value.
- SMC key enumeration: `#KEY`=2121 total keys. `plausibleTempKeys` (T-prefixed, `flt `, 5 < v < 130) = 217 — many more than a typical curated HID sensor list (Task 4). Names are opaque 4-char codes (e.g. `TC1x`/`TC2x`-`TC5x` per-core CPU clusters, `TD0x`/`TD1x`/`TD2x` likely SSD/NAND, `TH0x` heatpipe, `TPDx` proximity, `TB*T` battery, `TAOL` ambient) with no built-in human-readable names — M3 will need a hand-maintained name→label map (or cross-reference Task 4's HID sensor names once that spike lands; not compared here since it wasn't committed yet at spike time).
- Key enumeration cost: 0.45–0.57 s for the full 2121-key sweep (2 SMC round-trips per key: `kSMCGetKeyFromIndex` + `kSMCGetKeyInfo`/`kSMCReadKey` inside `read()`). **M3: enumerate once at startup, cache the key list (and types), and only re-read values on refresh** — do not re-enumerate every tick.
- Fan-under-load check: ran 8× `yes` for ~60 s (per Task 4's convention) then measured. **Caveat**: while this ran, a *different* worktree/session was concurrently running its own 8× `yes` load test for Task 4 (HID temps) on the same machine — 16 `yes` processes total were observed at once (pids 75928–75935 mine, 76722–76729 theirs). Both fan and temperature readings above reflect this combined load, not an isolated 8-process load. CPU-core temp keys (`TC1x` etc.) rose from ~70–73 °C idle to ~80–85 °C under load, consistent with the fan RPM increase. I killed only my own 8 `yes` pids; by the time I went to do so, both sets had already exited (the other session had run its own `killall yes`), so no cleanup action was actually needed on my end — noting this so it's clear I did not `killall yes` blindly and did not kill someone else's test.

## EXTRA — battery / power SMC keys vs IOKit `AppleSmartBattery`

Tested keys: `B0CT`, `B0FC`, `B0DC`, `B0TE`, `B0TF`, `PSTR`, `PDTR`, `B0AC`, `B0AV`, `CHBV`, `CHLC`.

- `CHLC` (charger limit current): **absent** on this hardware in this state (on battery, `ExternalConnected=No` in ioreg) — likely only populated while an adapter is attached.
- **Major finding: battery/charger SMC integer keys are little-endian**, unlike the fan/temp keys (which decode correctly big-endian, per the brief). Verified by decoding each key both ways and comparing against `ioreg -rw0 -c AppleSmartBattery` sampled at the same moment:
  | key | type | LE decode | ioreg field | match |
  |---|---|---|---|---|
  | `B0CT` | ui16 | 1855 | `CycleCount`=1855 | exact |
  | `B0FC` | ui16 | 4401–4405 | `AppleRawMaxCapacity`=4405 | exact (one sample) |
  | `B0DC` | ui16 | 6075 | `DesignCapacity`=6075 | exact |
  | `CHBV` | ui32 | 4214 | `ChargerData.ChargingVoltage`=4214 (mV) | exact |
  | `B0AC` | si16 | −2115..−3345 (mA) | `Amperage`/`InstantAmperage` (as two's-complement Int64) ≈ −1500..−3345 mA | same sign/order, not exact (different instant / smoothed channel) |
  | `B0AV` | ui16 | 10850–11130 (mV) | `Voltage`=10949–11268 (mV) | same order, not exact (pack sags under load, sampled a beat apart) |
  | `B0TE` | ui16 | 39–53 (min) | `TimeRemaining`=47 (min) | same order |
  | `B0TF` | ui16 | 0xFFFF both ways (sentinel "N/A") | `IsCharging`=No | consistent (not charging) |

  Big-endian decode of the same bytes gives nonsense (e.g. `B0CT` be=16135, `B0DC` be=47895, `CHBV` be≈1.98e9) — confirms these keys must be read LE, contrary to the general SMC convention used for temp/fan keys. **This is a real gotcha for M3**: don't assume one endianness for all SMC keys: verify per key-family.
  - `PSTR` (`flt `, system total power, W) and `PDTR` (`flt `, DC-in delivered power, W) already decode correctly under the brief's existing float rule (floats are always LE regardless of key family). `PDTR`=0.000 consistently, correct since the adapter is unplugged. `PSTR` ranged 15.7–32.3 W across samples — noisy because of the concurrent cross-worktree `yes` load noted above, not a measurement bug.

### Recommendation: which source to use for the Power/Battery screen

- **Cycle count**: IOKit `CycleCount` (or SMC `B0CT` LE — identical value). Prefer **IOKit**: no byte-order trap, already integer.
- **Health %**: compute from IOKit `AppleRawMaxCapacity / DesignCapacity` (or SMC `B0FC`/`B0DC` LE — identical numbers). Prefer **IOKit**. Note: the registry's own `MaxCapacity` key is a rounded, already-normalized percentage (100 in this sample) relative to `NominalChargeCapacity`, not raw — compute health explicitly from `AppleRawMaxCapacity/DesignCapacity` rather than trusting `MaxCapacity` at face value.
- **Charge/discharge power (W)**: IOKit has no clean instantaneous-Watts field (`PowerTelemetryData` is internal accumulators, not a simple gauge). Prefer **SMC `PSTR`/`PDTR`** — directly typed floats in Watts.
- **Temperature**: IOKit `Temperature`/`VirtualTemperature` (centi-°C, e.g. 3107 → 31.07 °C) is simple and validated. Prefer **IOKit**; no obvious single battery-temp SMC 4-char key was tested/found here.
- **Time remaining**: IOKit `TimeRemaining` (minutes) is already system-smoothed and matched SMC `B0TE` closely. Prefer **IOKit** — don't re-derive from raw current/capacity.
- **Instantaneous amperage/voltage** (for a live discharge graph): both sources agree in sign and order of magnitude. IOKit represents signed values as huge `UInt64` two's-complement numbers (e.g. `Amperage`=18446744073709548582) needing manual sign conversion; SMC `B0AC`/`B0AV` are natively `si16`/`ui16` but little-endian (the gotcha above). Prefer **IOKit** for consistency with the other picks above, accepting the two's-complement conversion as the lesser complexity vs. the SMC LE trap.
- **Overall**: IOKit's `AppleSmartBattery` registry is the simpler, better-documented source for nearly everything on this screen (health, cycles, temp, time remaining) and doesn't require reverse-engineered byte-order assumptions. SMC earns its keep only for **live system power in Watts** (`PSTR`/`PDTR`), which IOKit doesn't expose directly — M3 should read SMC for that one value and IOKit for the rest.

## Deviations from the brief
- `main.swift` extends the brief's `value()` with `si16` (signed, needed for `B0AC`) and `sp78` (fixed-point, unused in this run but common for other SMC families) decoding, plus a raw-hex + both-endian debug dump for the battery/power keys — needed to diagnose the LE-vs-BE finding above. Fan/temp logic is unchanged from the brief.
- `Spikes/Package.swift` was **not** modified — the `spike-smc` executable target already existed in it.
