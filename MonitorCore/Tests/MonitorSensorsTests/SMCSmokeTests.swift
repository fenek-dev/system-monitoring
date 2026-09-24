import Foundation
import Testing
@testable import MonitorModel
@testable import MonitorSensors

extension SMCKeySweep.Phase {
    var keysIfDone: [SMCKeySweep.Entry]? {
        if case let .done(k, _, _) = self { return k }
        return nil
    }
}

/// `TELLTALE_HW_TESTS=1 scripts/test.sh SMCSmokeTests`. The E-core experiment (~3 min) additionally needs
/// `TELLTALE_W6B_ECORE=1`.
@Suite(.enabled(if: W6bFixture.hardwareTests), .serialized, .w6bExclusive, .offCooperativePool)
struct SMCSmokeTests {
    /// The M1 Max 14" the catalog and these reference values were measured on.
    static let verifiedModel = "MacBookPro18,4"

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("w6b-smc-\(UUID().uuidString)", isDirectory: true)
    }

    private func avg(_ r: SMCReading, _ g: TemperatureGroup) -> Double? {
        let v = r.temperatures.filter { $0.group == g }.map(\.celsius)
        return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
    }

    private func describe(_ r: SMCReading) -> String {
        let groups = TemperatureGroup.allCases.compactMap { g in avg(r, g).map { "\(g.rawValue)=\(String(format: "%.1f", $0))" } }
        return "fans=\(r.fans.map { Int($0.rpm) }) PSTR=\(String(format: "%.1f", r.systemWatts ?? -1))W "
            + "PDTR=\(String(format: "%.1f", r.adapterWatts ?? -1))W " + groups.joined(separator: " ")
    }

    @Test func prepareReadsCatalogKeysAndSweepCaches() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stale = dir.appendingPathComponent("smc-keys-\(SMCKeySweep.safe(w6bHWModel))-OLD1.json")
        let other = dir.appendingPathComponent("smc-keys-Mac99,9-\(SMCKeySweep.safe(w6bOSBuild)).json")
        try Data("{}".utf8).write(to: stale)
        try Data("{}".utf8).write(to: other)
        let sensor = SMCSensor(hwModel: w6bHWModel, osBuild: w6bOSBuild, cacheDirectory: dir)
        let t0 = w6bUptimeNs()
        try sensor.prepare()
        let prepNs = w6bUptimeNs() - t0
        let r = try sensor.sample(SampleContext()).reading
        print("W6b smc: prepare=\(String(format: "%.1f", Double(prepNs) / 1e6))ms matched=\(r.catalogMatched) \(describe(r))")
        #expect(r.catalogMatched == (try TemperatureCatalog.bundled().model(for: w6bHWModel) != nil))
        for f in r.fans { #expect(f.maxRPM > f.minRPM && f.minRPM > 0 && f.rpm >= 0 && f.rpm <= f.maxRPM * 1.1) }
        #expect(r.systemWatts.map { $0 > 1 && $0 < 200 } == true)
        #expect(r.adapterWatts != nil)
        if w6bHWModel == Self.verifiedModel {        // values of the machine the catalog was verified on
            #expect(r.fans.count == 2)
            #expect(r.fans.first?.maxRPM == 5779)
            #expect(r.temperatures.filter { $0.group == .cpuPerformance }.count == 12)
            #expect(r.temperatures.filter { $0.group == .cpuEfficiency }.count == 8)
            #expect(r.temperatures.filter { $0.group == .gpu }.count == 8)
            #expect(r.temperatures.contains { $0.name == "TAOL" && $0.group == .airflow })
        } else {
            print("W6b smc: \(w6bHWModel) is not \(Self.verifiedModel); machine-specific checks skipped")
        }

        guard case let .done(keys, fromCache, ns) = sensor.sweep.wait() else { Issue.record("sweep failed"); return }
        print("W6b smc sweep: \(keys.count) T-keys in \(String(format: "%.0f", Double(ns) / 1e6))ms cache=\(fromCache)")
        #expect(!fromCache && keys.count > 100)
        #expect(FileManager.default.fileExists(atPath: sensor.sweep.cacheURL.path))
        #expect(!FileManager.default.fileExists(atPath: stale.path))      // this model, old build: pruned
        #expect(FileManager.default.fileExists(atPath: other.path))       // other model: kept
        let raw = try sensor.sample(SampleContext(demand: .rawTemperatures)).reading
        #expect(raw.temperatures.count > r.temperatures.count + 50)
        #expect(Set(raw.temperatures.map(\.name)).count == raw.temperatures.count)   // mapped keys not duplicated

        // Second sensor: sweep served from the cache file.
        let again = SMCSensor(hwModel: w6bHWModel, osBuild: w6bOSBuild, cacheDirectory: dir)
        try again.prepare()
        guard case let .done(k2, cached, _) = again.sweep.wait() else { Issue.record("cache load failed"); return }
        #expect(cached && k2 == keys)
    }

    /// SSD source decision: which SMC keys (if any) track `smartctl -a disk0` (NVMe composite temperature)?
    @Test func ssdCandidatesVsSmartctl() throws {
        let smart = (try? W6bFixture.run(["/opt/homebrew/bin/smartctl", "-a", "disk0"])) ?? ""
        guard let line = smart.split(separator: "\n").first(where: { $0.hasPrefix("Temperature:") }),
              let ref = Double(line.split(separator: " ").dropFirst().first ?? "") else {
            print("W6b smc ssd: smartctl unavailable"); return
        }
        let sensor = SMCSensor()
        try sensor.prepare()
        _ = sensor.sweep.wait()
        let raw = try sensor.sample(SampleContext(demand: .rawTemperatures)).reading.temperatures
        let td = raw.filter { $0.name.hasPrefix("Td0") }.map(\.celsius)
        let near = raw.filter { abs($0.celsius - ref) <= 1.5 }.map { "\($0.name)=\(String(format: "%.1f", $0.celsius))" }
        print("W6b smc ssd: smartctl=\(ref) Td0*avg=\(td.isEmpty ? -1 : td.reduce(0, +) / Double(td.count)) near=\(near)")
    }

    /// Shared, heat-soaked machine: baseline = minima over 5 quiet-ish seconds, load = maxima over ≤ 60 s.
    @Test func fansRiseUnderEightYes() throws {
        let sensor = SMCSensor()
        try sensor.prepare()
        var base: [SMCReading] = []
        for _ in 0..<5 { base.append(try sensor.sample(SampleContext()).reading); W6bFixture.sleep(1) }
        let yes = try W6bFixture.startYes(8)
        defer { W6bFixture.stop(yes) }
        // The fan controller lags and may still be spinning down from earlier load: "rise" = the largest
        // increase over the running minimum (base + load), so a decay-then-climb still counts.
        var load: [SMCReading] = []
        func rise(_ i: Int) -> Double {
            var lo = base.map { $0.fans[i].rpm }.min() ?? 0, best = 0.0
            for r in load { lo = min(lo, r.fans[i].rpm); best = max(best, r.fans[i].rpm - lo) }
            return best
        }
        for _ in 0..<24 {                       // up to 120 s
            W6bFixture.sleep(5)
            load.append(try sensor.sample(SampleContext()).reading)
            if (0..<base[0].fans.count).contains(where: { rise($0) >= 200 }) { break }
        }
        W6bFixture.stop(yes)
        let fanRise = (0..<base[0].fans.count).map(rise)
        let pBase = base.compactMap { avg($0, .cpuPerformance) }.min() ?? 0
        let pLoad = load.compactMap { avg($0, .cpuPerformance) }.max() ?? 0
        let wBase = base.compactMap(\.systemWatts).min() ?? 0
        let wLoad = load.compactMap(\.systemWatts).max() ?? 0
        print("W6b smc fans base: \(describe(base[0]))")
        print("W6b smc fans 8×yes: \(describe(load.last!)) rise=\(fanRise.map { Int($0) }) "
              + String(format: "P %.1f→%.1f°C PSTR %.1f→%.1fW (%ds)", pBase, pLoad, wBase, wLoad, load.count * 5))
        #expect(fanRise.contains { $0 >= 100 }, "fans did not rise: \(fanRise)")
        #expect(pLoad > pBase)
        #expect(wLoad > wBase)
    }

    /// E-core mapping check (temps.md "Production verification (W6b)"): time series of every TC*/Tp* key vs
    /// IOReport ECPU/PCPU watts + residency across base → 4× background-QoS yes (E-cores) → cool → 8× yes (P) → cool.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TELLTALE_W6B_ECORE"] == "1"))
    func eCoreCorrelation() throws {
        let smc = SMCSensor()
        try smc.prepare()
        guard let keys = smc.sweep.wait().keysIfDone else { Issue.record("sweep"); return }
        let soc = IOReportSensor()
        try soc.prepare()
        try #require(soc.waitUntilReady())
        _ = try soc.sample(SampleContext())
        let raw = SampleContext(demand: .rawTemperatures)
        let names = keys.map(\.key).filter { $0.hasPrefix("TC") || $0.hasPrefix("Tp") }
        var series: [String: [Double]] = [:]
        var eW: [Double] = [], pW: [Double] = [], eAct: [Double] = [], pAct: [Double] = [], phase: [String] = []
        func tick(_ label: String, _ seconds: Int) throws {
            for _ in 0..<(seconds / 2) {
                W6bFixture.sleep(2)
                let s = try soc.sample(SampleContext()).reading
                let t = Dictionary(try smc.sample(raw).reading.temperatures.map { ($0.name, $0.celsius) }, uniquingKeysWith: { a, _ in a })
                for n in names { series[n, default: []].append(t[n] ?? .nan) }
                let e = s.clusters.filter { $0.kind == .efficiency }, p = s.clusters.filter { $0.kind == .performance }
                eW.append(e.compactMap(\.watts).reduce(0, +)); pW.append(p.compactMap(\.watts).reduce(0, +))
                eAct.append(e.map(\.activeFraction).reduce(0, +) / Double(max(1, e.count)))
                pAct.append(p.map(\.activeFraction).reduce(0, +) / Double(max(1, p.count)))
                phase.append(label)
            }
        }
        try tick("base", 20)
        var yes = try W6bFixture.startYes(4, background: true)
        defer { W6bFixture.stop(yes) }
        try tick("E", 40)
        W6bFixture.stop(yes)
        try tick("coolE", 40)
        yes = try W6bFixture.startYes(8)
        try tick("P", 40)
        W6bFixture.stop(yes)
        try tick("coolP", 20)

        func mean(_ xs: [Double]) -> Double { xs.isEmpty ? .nan : xs.reduce(0, +) / Double(xs.count) }
        func at(_ xs: [Double], _ label: String, last n: Int) -> [Double] {
            Array(zip(xs, phase).filter { $0.1 == label }.map(\.0).suffix(n))
        }
        func corr(_ a: [Double], _ b: [Double]) -> Double {
            let pairs = zip(a, b).filter { $0.0.isFinite && $0.1.isFinite }
            let ma = mean(pairs.map(\.0)), mb = mean(pairs.map(\.1))
            let cov = pairs.reduce(0) { $0 + ($1.0 - ma) * ($1.1 - mb) }
            let va = pairs.reduce(0) { $0 + ($1.0 - ma) * ($1.0 - ma) }, vb = pairs.reduce(0) { $0 + ($1.1 - mb) * ($1.1 - mb) }
            return va > 0 && vb > 0 ? cov / (va * vb).squareRoot() : .nan
        }
        print(String(format: "W6b ecore residency: E base %.0f%% → E-load %.0f%% | P base %.0f%% → E-load %.0f%% → P-load %.0f%%",
                     mean(at(eAct, "base", last: 5)) * 100, mean(at(eAct, "E", last: 10)) * 100,
                     mean(at(pAct, "base", last: 5)) * 100, mean(at(pAct, "E", last: 10)) * 100, mean(at(pAct, "P", last: 10)) * 100))
        print(String(format: "W6b ecore watts: E base %.2f → E-load %.2f W | P base %.2f → E-load %.2f → P-load %.2f W",
                     mean(at(eW, "base", last: 5)), mean(at(eW, "E", last: 10)), mean(at(pW, "base", last: 5)),
                     mean(at(pW, "E", last: 10)), mean(at(pW, "P", last: 10))))
        // Families: TC1…TC5 (4 keys each), Tp0* individually.
        var rows: [(String, Double, Double, Double, Double)] = []
        let families = Dictionary(grouping: names.filter { $0.hasPrefix("TC") }) { String($0.prefix(3)) }
        var groups: [(String, [String])] = families.map { ($0.key + "x", $0.value) }
        groups += names.filter { $0.hasPrefix("Tp") }.map { ($0, [$0]) }
        for (label, ks) in groups {
            let s = (0..<phase.count).map { i in mean(ks.compactMap { series[$0]?[i] }.filter(\.isFinite)) }
            let dE = mean(at(s, "E", last: 5)) - mean(at(s, "base", last: 5))
            let dP = mean(at(s, "P", last: 5)) - mean(at(s, "coolE", last: 5))
            rows.append((label, dE, dP, corr(s, eW), corr(s, pW)))
        }
        for r in rows.sorted(by: { ($0.1 - 0.2 * $0.2) > ($1.1 - 0.2 * $1.2) }) {
            print(String(format: "W6b ecore %@ dE=%+.1f dP=%+.1f corrEW=%+.2f corrPW=%+.2f", r.0, r.1, r.2, r.3, r.4))
        }
    }

    @Test func bench() throws {
        let sensor = SMCSensor()
        try sensor.prepare()
        _ = sensor.sweep.wait()
        func run(_ demand: SamplingDemand, _ n: Int) throws -> (String, Int) {
            var ns: [UInt64] = []
            var count = 0
            for _ in 0..<n {
                let t = w6bUptimeNs()
                count = try sensor.sample(SampleContext(demand: demand)).reading.temperatures.count
                ns.append(w6bUptimeNs() - t)
            }
            return (w6bPercentiles(ns), count)
        }
        let cat = try run([], 30)
        let raw = try run(.rawTemperatures, 10)
        print("W6b bench smc catalog \(cat.0) temps=\(cat.1); raw \(raw.0) temps=\(raw.1)")
    }
}
