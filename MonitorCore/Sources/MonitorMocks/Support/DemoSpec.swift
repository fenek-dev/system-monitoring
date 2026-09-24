import Foundation

/// One parameter set for a `DemoSeries` (seed, base, volatility, clamp range). Values below are lifted
/// verbatim from the design artboards' inline generators (`docs/design/artboards/*.dc.html`, `var SPEC`),
/// so `.calm` reproduces the reference renders' headline numbers (e.g. CPU base 34%, GPU base 18%,
/// Memory base 15.1 GB, Network base 12.4/0.84 MB/s, SoC temp base 62°C, package power base 18.6 W).
struct DemoParam {
    var seed: UInt32
    var base, vol, min, max: Double
}

/// Every named noise series a mock scenario can drive, keyed by the same short names the artboards use.
enum DemoKey: Hashable, CaseIterable {
    // Common (every screen; MenuBar/Overview headline numbers).
    case cpu, gpu, mem, netd, netu, temp, pwr
    // CPU page: 8 performance + 4 efficiency per-core percents, user/system split.
    case p0, p1, p2, p3, p4, p5, p6, p7
    case e0, e1, e2, e3
    case usr, sys
    // GPU page.
    case gfreq, enc
    // Memory page.
    case press, swap
    // Thermals page.
    case tp, tg, tb, fan1, fan2
    // Power page.
    case pc, pg, pa, pd
    // Disk page.
    case rd, wr
}

enum DemoSpec {
    /// `.calm` parameters, extracted from the artboards (CPU/GPU/Memory/Thermals/Power/Disk `.dc.html`).
    static let calm: [DemoKey: DemoParam] = [
        .cpu: DemoParam(seed: 11, base: 34, vol: 9, min: 3, max: 100),
        .gpu: DemoParam(seed: 23, base: 18, vol: 7, min: 0, max: 100),
        .mem: DemoParam(seed: 37, base: 15.1, vol: 0.25, min: 12, max: 23),
        .netd: DemoParam(seed: 41, base: 12.4, vol: 5, min: 0.2, max: 60),
        .netu: DemoParam(seed: 43, base: 0.84, vol: 0.5, min: 0.02, max: 8),
        .temp: DemoParam(seed: 53, base: 62, vol: 2.2, min: 44, max: 98),
        .pwr: DemoParam(seed: 59, base: 18.6, vol: 3, min: 4, max: 80),

        .p0: DemoParam(seed: 200, base: 72, vol: 14, min: 1, max: 100),
        .p1: DemoParam(seed: 201, base: 64, vol: 14, min: 1, max: 100),
        .p2: DemoParam(seed: 202, base: 58, vol: 14, min: 1, max: 100),
        .p3: DemoParam(seed: 203, base: 41, vol: 14, min: 1, max: 100),
        .p4: DemoParam(seed: 204, base: 33, vol: 14, min: 1, max: 100),
        .p5: DemoParam(seed: 205, base: 22, vol: 14, min: 1, max: 100),
        .p6: DemoParam(seed: 206, base: 12, vol: 14, min: 1, max: 100),
        .p7: DemoParam(seed: 207, base: 8, vol: 14, min: 1, max: 100),
        .e0: DemoParam(seed: 300, base: 38, vol: 10, min: 1, max: 100),
        .e1: DemoParam(seed: 301, base: 31, vol: 10, min: 1, max: 100),
        .e2: DemoParam(seed: 302, base: 27, vol: 10, min: 1, max: 100),
        .e3: DemoParam(seed: 303, base: 19, vol: 10, min: 1, max: 100),
        .usr: DemoParam(seed: 401, base: 22, vol: 6, min: 1, max: 70),
        .sys: DemoParam(seed: 402, base: 12, vol: 3, min: 1, max: 30),

        .gfreq: DemoParam(seed: 501, base: 1180, vol: 160, min: 340, max: 1578),
        .enc: DemoParam(seed: 503, base: 22, vol: 8, min: 0, max: 100),

        .press: DemoParam(seed: 601, base: 38, vol: 5, min: 5, max: 99),
        .swap: DemoParam(seed: 602, base: 1.2, vol: 0.05, min: 0.9, max: 1.6),

        .tp: DemoParam(seed: 701, base: 66, vol: 2.5, min: 40, max: 105),
        .tg: DemoParam(seed: 702, base: 58, vol: 2, min: 40, max: 105),
        .tb: DemoParam(seed: 703, base: 31, vol: 0.3, min: 25, max: 50),
        .fan1: DemoParam(seed: 704, base: 2140, vol: 60, min: 1200, max: 5700),
        .fan2: DemoParam(seed: 705, base: 2210, vol: 60, min: 1200, max: 5700),

        .pc: DemoParam(seed: 801, base: 10.8, vol: 2.5, min: 0.5, max: 40),
        .pg: DemoParam(seed: 802, base: 4.1, vol: 1.2, min: 0.1, max: 30),
        .pa: DemoParam(seed: 803, base: 0.3, vol: 0.2, min: 0, max: 8),
        .pd: DemoParam(seed: 804, base: 1.6, vol: 0.2, min: 0.6, max: 5),

        .rd: DemoParam(seed: 901, base: 142, vol: 40, min: 0, max: 900),
        .wr: DemoParam(seed: 902, base: 38, vol: 15, min: 0, max: 600),
    ]

    /// Per-scenario overrides layered on top of `.calm` (only the keys that differ).
    static func params(for scenario: MockScenario) -> [DemoKey: DemoParam] {
        var p = calm
        switch scenario {
        case .calm, .collecting, .paused, .restricted, .runaway, .deviceUnknown:
            break

        case .thermalFair:
            // MenuBarAlert.dc.html SPEC (thermal pressure: Fair).
            p[.cpu] = DemoParam(seed: 11, base: 71, vol: 8, min: 30, max: 100)
            p[.gpu] = DemoParam(seed: 23, base: 41, vol: 7, min: 0, max: 100)
            p[.temp] = DemoParam(seed: 53, base: 84, vol: 1.5, min: 70, max: 98)
            p[.pwr] = DemoParam(seed: 59, base: 42.5, vol: 4, min: 20, max: 80)
            p[.fan1] = DemoParam(seed: 704, base: 3900, vol: 80, min: 3000, max: 5700)
            p[.fan2] = DemoParam(seed: 705, base: 3900, vol: 80, min: 3000, max: 5700)
            p[.tp] = DemoParam(seed: 701, base: 88, vol: 2, min: 70, max: 105)

        case .thermalCritical:
            p[.cpu] = DemoParam(seed: 11, base: 78, vol: 8, min: 40, max: 100)
            p[.gpu] = DemoParam(seed: 23, base: 55, vol: 7, min: 10, max: 100)
            p[.temp] = DemoParam(seed: 53, base: 96, vol: 1.2, min: 88, max: 108)
            p[.pwr] = DemoParam(seed: 59, base: 58, vol: 4, min: 30, max: 90)
            p[.fan1] = DemoParam(seed: 704, base: 5700, vol: 40, min: 5200, max: 5700)
            p[.fan2] = DemoParam(seed: 705, base: 5700, vol: 40, min: 5200, max: 5700)
            p[.tp] = DemoParam(seed: 701, base: 100, vol: 1.5, min: 88, max: 108)

        case .memoryWarning:
            p[.mem] = DemoParam(seed: 37, base: 19.5, vol: 0.3, min: 17, max: 23)
            p[.press] = DemoParam(seed: 601, base: 64, vol: 4, min: 60, max: 79)
            p[.swap] = DemoParam(seed: 602, base: 1.8, vol: 0.08, min: 1.5, max: 2.0)

        case .memoryCritical:
            p[.mem] = DemoParam(seed: 37, base: 22.4, vol: 0.2, min: 20, max: 23.5)
            p[.press] = DemoParam(seed: 601, base: 87, vol: 3, min: 80, max: 99)
            p[.swap] = DemoParam(seed: 602, base: 3.6, vol: 0.15, min: 3.0, max: 4.0)

        case .sensorsUnavailable:
            // soc/smc/networkFlows are unavailable (handled by the caller); keep host-CPU-only signals.
            break
        }
        return p
    }
}
