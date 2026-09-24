# ICR 001 — W6d — `BlockDriverCounter.isDiskImage`

**Stream:** W6d (disk sensors)
**Status:** proposed — not applied to `MonitorModel` by this stream (ARCHITECTURE §9: model changes
are ICR'd, then landed by the integrator; the stream uses a local extension meanwhile).

## What

Add one additive field to `BlockDriverCounter` (`MonitorModel/Readings/Disk.swift`):

```swift
public struct BlockDriverCounter: Sendable, Codable, Hashable {
    public var bsdName: String?, isInternal: Bool
    public var readOps, writeOps, readBytes, writeBytes: UInt64
    public var isDiskImage: Bool = false   // NEW

    public init(
        bsdName: String? = nil,
        isInternal: Bool = false,
        readOps: UInt64 = 0,
        writeOps: UInt64 = 0,
        readBytes: UInt64 = 0,
        writeBytes: UInt64 = 0,
        isDiskImage: Bool = false          // NEW
    ) {
        self.bsdName = bsdName
        self.isInternal = isInternal
        self.readOps = readOps
        self.writeOps = writeOps
        self.readBytes = readBytes
        self.writeBytes = writeBytes
        self.isDiskImage = isDiskImage     // NEW
    }
}
```

Purely additive: a new field with a default value, appended after the existing parameters (source-
and binary-compatible with every existing call site — today, that's only `DiskIOSensor` itself).

## Why

`IOBlockStorageDriver` enumeration (findings/extras.md §1) surfaces one driver per mounted disk image
(`.dmg`) alongside real hardware drivers. A disk image's reported I/O is not independent activity: the
disk-image driver translates its own reads/writes into reads/writes on the *backing file*, which lives
on a real physical driver (usually the boot disk). Summing `readBytes`/`writeBytes` across **all**
drivers to get a system-wide disk-I/O total (the natural thing a `DiskSnapshot` assembler will want to
do for `readBps`/`writeBps`) would double-count that activity: once as the disk image driver's own
numbers, once again as part of the physical driver's numbers for writing the backing file.

`isInternal` is not a usable proxy for this: a genuine external USB/Thunderbolt SSD is also
`isInternal == false` but its I/O is real, independent hardware activity that a system total *should*
include. Disk-image-ness is a distinct concept from internal/external and needs its own field.

## Detection (already implemented, real-hardware verified)

`MonitorSensors/Support/W6d+DiskRegistry.swift`'s `ttIsDiskImageDriver(_ driver: io_service_t) -> Bool`:
the driver's parent in the `IOService` plane is a class whose name contains `"DiskImage"` (confirmed
live: `AppleDiskImageDevice` and `IODiskImageBlockStorageDeviceInKernel` both appear on this machine's
mounted `.dmg`s; the internal NVMe SSD's parent is `IOEmbeddedNVMeBlockDevice`, an SD card reader's is
`AppleSDXCBlockStorageDevice` — neither matches). Covered by
`DiskIOSmokeTests.diskImageDriversAreDistinguishedFromRealHardware` (gated `TELLTALE_HW_TESTS=1`),
which asserts both directions against this machine's real internal SSD and real mounted disk images.

## Wiring (one line, once the field lands)

`DiskIOSensor.sample()` (`MonitorSensors/Disk/DiskIOSensor.swift`) constructs each
`BlockDriverCounter`; add `isDiskImage: ttIsDiskImageDriver(driver)` to that call. No other change
needed on the W6d side.

## Affected streams

- **W1 (MonitorEngine)**: whichever assembler computes `DiskSnapshot.readBps`/`writeBps` from
  `DiskIOReading.drivers` (not yet written as of this ICR — `FrameAssembler.swift` has no disk code
  yet) should sum only `!isDiskImage` drivers for the system-wide total, same rationale as above.
- **W5b (DiskPage)**: if a future per-driver breakdown UI lists drivers, `isDiskImage` may be worth
  showing/filtering on (e.g. "Disk 0 (SSD)" vs. "Disk Image (My.dmg)").
- No store/history schema impact — this is a `Reading`-layer field, not a `HistoryMetric`.

## Compatibility

Additive only (ARCHITECTURE §9): a new field with a default, no reordering, no removed field, no
signature change to `Sensor`/`SensorSuite`/`RawTick`. Existing fixtures/JSON without `isDiskImage`
decode fine (defaults to `false`) since `Codable`'s synthesized decoder treats an `Encodable` struct's
newly-added `Bool = false` property as present-with-default when absent — *provided* the integrator
also gives it an explicit `decodeIfPresent`-style custom `init(from:)` if `BlockDriverCounter` doesn't
already have one; if it currently relies on the fully-synthesized `Codable` conformance, a decode
against an *old* recorded fixture missing the key will throw `keyNotFound` unless the field is declared
optional or the type adds `decodeIfPresent(..., default: false)` in a custom initializer. (This
repo's `RawTick.init(from:)` already uses `decodeIfPresent` for exactly this forward-compatibility
reason — worth the same treatment here if `BlockDriverCounter` doesn't special-case it.)
