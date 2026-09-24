import Foundation
import MonitorEngine
import MonitorModel
import MonitorSensors
import MonitorStore

/// The probe's commands. Single-sensor modes call the sensor directly; `--record`/`--frames` and the engine half of
/// `--bench` go through `SamplingEngine.sampleOnceRaw()` (ARCHITECTURE §5.6), never the loop.
enum Commands {
    static let readingEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    // MARK: --list

    static func list(_ o: ProbeOptions) {
        let sensors = ProbeSensor.all(SensorFactory.live.make(o.disabled))
        print("sensor            cadence                                   prepare (ms)  status")
        var unavailable = 0
        for s in sensors {
            let t0 = Clock.ns()
            let err = s.prepare()
            let dt = Clock.ns() - t0
            if err != nil { unavailable += 1 }
            let status = err.map(\.probeDescription) ?? "ok"
            print(pad(s.id.rawValue, 17), pad(s.cadence.probeDescription, 41), pad(Clock.ms(dt), 13), status)
            s.invalidate()
        }
        print("\(sensors.count - unavailable)/\(sensors.count) available")
    }

    // MARK: --sensor

    static func sensor(_ id: SensorID, _ o: ProbeOptions) async {
        guard let s = ProbeSensor.all(SensorFactory.live.make(o.disabled)).first(where: { $0.id == id }) else { return }
        print("\(id.rawValue): cadence \(s.cadence.probeDescription); mode \(o.mode) demand \(ProbeOptions.describe(o.demand))")
        if !s.wanted(mode: o.mode, demand: o.demand) {
            print("note: the engine would not sample it in this mode/demand (sampling anyway)")
        }
        let t0 = Clock.ns()
        if let err = s.prepare() {
            print("prepare: \(err.probeDescription) (\(Clock.ms(Clock.ns() - t0)) ms)")
            return
        }
        print("prepare: ok (\(Clock.ms(Clock.ns() - t0)) ms)")
        var dumps: [Data] = []
        var last: ProbeSensor.Sampled?
        var stats = Stats()
        await everyInterval(o) { k in
            let ctx = SampleContext(uptimeNs: Clock.ns(), wallTime: Date(), mode: o.mode, demand: o.demand)
            let t = Clock.ns()
            let r = s.sample(ctx)
            let dt = Clock.ns() - t
            stats.add(dt)
            switch r {
            case .success(let sampled):
                last = sampled
                let data = (try? sampled.encode(readingEncoder)) ?? Data()
                if o.dump != nil { dumps.append(data) }
                if !o.quiet {
                    print("tick \(k): \(Clock.ms(dt)) ms, capturedNs \(sampled.capturedNs), \(data.count) B json")
                }
            case .failure(let e):
                print("tick \(k): \(Clock.ms(dt)) ms, \(e.probeDescription)")
            }
        }
        s.invalidate()
        print("cost ms: p50 \(Clock.ms(stats.percentile(0.5))) p95 \(Clock.ms(stats.percentile(0.95))) max \(Clock.ms(stats.max))")
        if let last, let data = try? last.encode(readingEncoder), let text = String(data: data, encoding: .utf8) {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let limit = o.json ? lines.count : 60
            print("last reading:")
            print(lines.prefix(limit).joined(separator: "\n"))
            if lines.count > limit { print("… \(lines.count - limit) more lines (--json for all, --dump <file>)") }
        }
        if let path = o.dump {
            var out = Data("[".utf8)
            out.append(dumps.joined(separator: Data(",".utf8)).reduce(into: Data()) { $0.append($1) })
            out.append(Data("]".utf8))
            write(out, to: path)
        }
    }

    // MARK: --bench

    static func bench(_ o: ProbeOptions) async {
        let all = ProbeSensor.all(SensorFactory.live.make(o.disabled))
        let sensors = o.benchSensor.map { id in all.filter { $0.id == id } } ?? all
        print("bench: \(o.ticks) ticks, interval \(o.interval), mode \(o.mode), demand \(ProbeOptions.describe(o.demand))")
        var prepareNs: [SensorID: UInt64] = [:]
        var ready: [ProbeSensor] = []
        for s in sensors {
            let t = Clock.ns()
            let err = s.prepare()
            prepareNs[s.id] = Clock.ns() - t
            if let err { print("\(s.id.rawValue): \(err.probeDescription)") } else { ready.append(s) }
        }
        var per: [SensorID: Stats] = [:]
        var failures: [SensorID: Int] = [:]
        var tickTotal = Stats()
        await everyInterval(o) { _ in
            let ctx = SampleContext(uptimeNs: Clock.ns(), wallTime: Date(), mode: o.mode, demand: o.demand)
            let t0 = Clock.ns()
            for s in ready {
                let t = Clock.ns()
                if case .failure = s.sample(ctx) { failures[s.id, default: 0] += 1 }
                per[s.id, default: Stats()].add(Clock.ns() - t)
            }
            tickTotal.add(Clock.ns() - t0)
        }
        for s in ready { s.invalidate() }

        print("\ndirect sample() cost (ms; every sensor every tick, cadence ignored)")
        print("sensor            p50     p95     max     total   prepare  fails  in-mode")
        var wantedTotal = Stats()
        wantedTotal.samples = Array(repeating: 0, count: o.ticks)
        for s in ready {
            let st = per[s.id] ?? Stats()
            let wanted = s.wanted(mode: o.mode, demand: o.demand)
            if wanted { for (k, v) in st.samples.enumerated() where k < o.ticks { wantedTotal.samples[k] += v } }
            print(pad(s.id.rawValue, 17), pad(Clock.ms(st.percentile(0.5)), 7), pad(Clock.ms(st.percentile(0.95)), 7),
                  pad(Clock.ms(st.max), 7), pad(Clock.ms(st.total), 7), pad(Clock.ms(prepareNs[s.id] ?? 0), 8),
                  pad("\(failures[s.id] ?? 0)", 6), wanted ? "yes" : "no")
        }
        print("per tick, all sensors:   p50 \(Clock.ms(tickTotal.percentile(0.5))) p95 \(Clock.ms(tickTotal.percentile(0.95))) max \(Clock.ms(tickTotal.max))")
        print("per tick, in-mode only:  p50 \(Clock.ms(wantedTotal.percentile(0.5))) p95 \(Clock.ms(wantedTotal.percentile(0.95))) max \(Clock.ms(wantedTotal.max))")

        guard o.benchSensor == nil else { return }
        // Full engine ticks: SensorSlot cadence/cache + assembly + alerts + record.
        let engine = SamplingEngine(factory: .live, disabled: o.disabled, canary: .none)
        await engine.setVisibility(o.visibility)
        var engineTicks = Stats()
        await everyInterval(o) { _ in
            let t = Clock.ns()
            _ = await engine.sampleOnceRaw()
            engineTicks.add(Clock.ns() - t)
        }
        let first = engineTicks.samples.first ?? 0
        var steady = Stats()
        steady.samples = Array(engineTicks.samples.dropFirst())
        print("\nengine sampleOnceRaw (visibility mode \(o.visibility.mode), demand \(ProbeOptions.describe(o.visibility.demand)))")
        print("first tick \(Clock.ms(first)) ms (prepare); steady p50 \(Clock.ms(steady.percentile(0.5))) p95 \(Clock.ms(steady.percentile(0.95))) max \(Clock.ms(steady.max)) mean \(Clock.ms(steady.mean))")
        let costs = await engine.sensorCosts()
        print("slot cost (ms; SensorSlot, cadence applied): sensor last/mean/p95")
        for id in SensorID.allCases {
            guard let c = costs[id], c.mean > 0 else { continue }
            print("  \(pad(id.rawValue, 17)) \(Clock.ms(c.last)) / \(Clock.ms(c.mean)) / \(Clock.ms(c.p95))")
        }
        await engine.stop()
    }

    // MARK: --record / --frames

    static func record(to path: String, _ o: ProbeOptions) async {
        let engine = SamplingEngine(factory: .live, disabled: o.disabled, canary: .none)
        await engine.setVisibility(o.visibility)
        var ticks: [RawTick] = []
        print("record: \(o.ticks) ticks, interval \(o.interval), visibility mode \(o.visibility.mode) → \(path)")
        await everyInterval(o) { k in
            let (tick, frame) = await engine.sampleOnceRaw()
            ticks.append(tick)
            if !o.quiet { print("tick \(k): \(Report.oneLine(frame))") }
        }
        await engine.stop()
        do {
            let data = try FixtureFormat.encoder.encode(ticks)
            write(data, to: path)
        } catch {
            print("encode failed: \(error)")
            exit(1)
        }
    }

    static func frames(_ o: ProbeOptions) async {
        let engine = SamplingEngine(factory: .live, disabled: o.disabled, canary: .none)
        await engine.setVisibility(o.visibility)
        await everyInterval(o) { k in
            let (_, frame) = await engine.sampleOnceRaw()
            print("── tick \(k)")
            print(Report.frame(frame, verbose: !o.quiet))
        }
        await engine.stop()
    }

    // MARK: --maintain-now

    static func maintainNow(_ o: ProbeOptions) async {
        let dir = URL(fileURLWithPath: o.dataDir ?? ProcessInfo.processInfo.environment["TELLTALE_DATA_DIR"]
            ?? (NSHomeDirectory() + "/Library/Application Support/dev.telltale"))
        let db = dir.appendingPathComponent("history.sqlite")
        guard FileManager.default.fileExists(atPath: db.path) else {
            print("no database at \(db.path)")
            exit(1)
        }
        print("database: \(db.path)")
        print("before: \(sizes(db))")
        do {
            let t0 = Clock.ns()
            let store = try HistoryStore(location: .file(db), config: StoreConfig(maintenanceInterval: .zero))
            let opened = Clock.ns()
            try await store.maintain(now: Date())
            let maintained = Clock.ns()
            let coverage = try await store.coverage()
            try await store.shutdown()
            print("open \(Clock.ms(opened - t0)) ms, maintain \(Clock.ms(maintained - opened)) ms")
            if let c = coverage {
                print("coverage: \(c.start) → \(c.end) (\(String(format: "%.1f", c.duration / 3600)) h)")
            } else {
                print("coverage: none")
            }
        } catch {
            print("maintain failed: \(error)")
            exit(1)
        }
        print("after:  \(sizes(db))")
    }

    // MARK: --crash-sensor

    static func crash(_ id: SensorID, _ o: ProbeOptions) async {
        print("crash drill: SensorFactory.live.crashing(\(id.rawValue)) — expect abort() in its first prepare()")
        fflush(stdout)
        let engine = SamplingEngine(factory: SensorFactory.live.crashing(id), disabled: o.disabled, canary: .none)
        _ = await engine.sampleOnceRaw()
        print("no crash: \(id.rawValue) was never prepared (disabled or not requested in this mode)")
    }

    // MARK: - Helpers

    /// Runs `body` o.ticks times, aligned to deadlines `start + k·interval` (continuous clock).
    static func everyInterval(_ o: ProbeOptions, _ body: (Int) async -> Void) async {
        let clock = ContinuousClock()
        let start = clock.now
        for k in 0..<o.ticks {
            if k > 0 { try? await Task.sleep(until: start + o.interval * k, clock: clock) }
            await body(k)
        }
    }

    static func sizes(_ db: URL) -> String {
        ["", "-wal", "-shm"].map { suffix in
            let path = db.path + suffix
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? nil
            return "\(db.lastPathComponent)\(suffix) \(size.map { String(format: "%.2f MB", Double($0) / 1_048_576) } ?? "—")"
        }.joined(separator: ", ")
    }

    static func write(_ data: Data, to path: String) {
        do {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            print("wrote \(path) (\(String(format: "%.1f", Double(data.count) / 1024)) KB)")
        } catch {
            print("write \(path) failed: \(error)")
            exit(1)
        }
    }
}

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
}

/// `[RawTick]` fixture coding: W1's shared format (`MonitorEngine/Fixtures/FixtureCoding.swift`).
enum FixtureFormat {
    static var encoder: JSONEncoder { RawTick.fixtureEncoder }
}
