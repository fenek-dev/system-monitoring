import Foundation

/// The full set of noise series for one scenario, built once and evaluated at any tick.
/// Series seeds are the artboards' own (never perturbed by `MockDataProvider.seed`), so `.calm` matches
/// the reference renders regardless of the seed a caller passes; `seed` instead perturbs the
/// demo app roster and history noise (`DemoApps`, `MockHistoryProvider`), which have no artboard reference.
struct DemoSignals {
    private let series: [DemoKey: DemoSeries]

    init(scenario: MockScenario) {
        var s: [DemoKey: DemoSeries] = [:]
        for (key, p) in DemoSpec.params(for: scenario) {
            s[key] = DemoSeries(seed: p.seed, base: p.base, vol: p.vol, min: p.min, max: p.max)
        }
        series = s
    }

    func value(_ key: DemoKey, at tick: Int) -> Double {
        guard let s = series[key] else { return 0 }
        return s.value(afterTicks: tick)
    }
}
