import Foundation
import MonitorModel

/// Command line of `telltale-probe` (W7 T2). One command per run; see `ProbeOptions.usage`.
struct ProbeOptions: Sendable {
    enum Command: Sendable, Equatable {
        case list, sensor(SensorID), bench, record(String), frames, maintainNow, crash(SensorID), help
    }

    var command: Command = .help
    var ticks = 5
    var interval: Duration = .seconds(1)
    var mode: SamplingMode = .background
    var modeGiven = false
    var demand: SamplingDemand = []
    var page: DashboardPage?
    var benchSensor: SensorID?
    var dump: String?
    var dataDir: String?
    var disabled: Set<SensorID> = []
    var quiet = false
    var json = false
    var trimIdle = false

    static let usage = """
    telltale-probe — exercise Telltale sensors, the engine and the store without the app.

      --list                         every sensor: cadence, prepare() result / unavailable reason
      --sensor <id>                  sample one sensor directly (no engine); prints the last reading
      --bench [--sensor <id>]        per-sensor sample() cost p50/p95/max + total, then full engine ticks
      --record <file> [--trim-idle]  engine ticks → [RawTick] JSON (fixture format); --trim-idle drops processes and
                                     coalitions whose counters never change (deltas unchanged; see FixtureTrim)
      --frames                       engine ticks → frame summaries (system + top apps)
      --maintain-now [--data-dir d]  flush + rollup + retention + vacuum on d/history.sqlite
      --crash-sensor <id>            engine with SensorFactory.crashing(id): aborts in the first prepare()

    options:
      --ticks N (5)  --interval S (1)  --mode background|interactive
      --demand a,b   (perCore,connections,rawTemperatures,wifi,smart,volumes,sleepAssertions,processTable,memoryAlert,all)
      --page <page>  engine visibility: dashboard page (implies interactive)
      --dump <file>  --sensor: write every reading as JSON
      --disable a,b|all  sensors to replace with UnavailableSensor (also TELLTALE_DISABLE_SENSORS)
      --json         --sensor: print the full last reading      --quiet  less per-tick output
    sensors: \(SensorID.allCases.map(\.rawValue).joined(separator: ","))
    """

    struct ParseError: Error, CustomStringConvertible { var description: String }

    static func parse(_ args: [String], env: [String: String]) throws(ParseError) -> ProbeOptions {
        var o = ProbeOptions()
        var sensorArg: SensorID?
        var bench = false
        var i = 0
        func value(_ flag: String) throws(ParseError) -> String {
            i += 1
            guard i < args.count else { throw ParseError(description: "\(flag) needs a value") }
            return args[i]
        }
        func sensorID(_ s: String) throws(ParseError) -> SensorID {
            guard let id = SensorID(rawValue: s) else { throw ParseError(description: "unknown sensor \(s)") }
            return id
        }
        var command: Command?
        while i < args.count {
            let a = args[i]
            switch a {
            case "--list": command = .list
            case "--sensor": sensorArg = try sensorID(try value(a))
            case "--bench": bench = true
            case "--record": command = .record(try value(a))
            case "--frames": command = .frames
            case "--maintain-now": command = .maintainNow
            case "--crash-sensor": command = .crash(try sensorID(try value(a)))
            case "--ticks":
                guard let n = Int(try value(a)), n > 0 else { throw ParseError(description: "--ticks N > 0") }
                o.ticks = n
            case "--interval":
                guard let s = Double(try value(a)), s >= 0 else { throw ParseError(description: "--interval S ≥ 0") }
                o.interval = .milliseconds(Int64(s * 1000))
            case "--mode":
                switch try value(a) {
                case "background": o.mode = .background
                case "interactive": o.mode = .interactive
                case let m: throw ParseError(description: "unknown mode \(m)")
                }
                o.modeGiven = true
            case "--demand": o.demand = try parseDemand(try value(a))
            case "--page":
                let p = try value(a)
                guard let page = DashboardPage(rawValue: p) else { throw ParseError(description: "unknown page \(p)") }
                o.page = page
            case "--dump": o.dump = try value(a)
            case "--data-dir": o.dataDir = try value(a)
            case "--disable": o.disabled.formUnion(try parseSensors(try value(a)))
            case "--quiet": o.quiet = true
            case "--json": o.json = true
            case "--trim-idle": o.trimIdle = true
            case "-h", "--help": command = .help
            default: throw ParseError(description: "unknown argument \(a)")
            }
            i += 1
        }
        if let env = env["TELLTALE_DISABLE_SENSORS"], !env.isEmpty { o.disabled.formUnion(try parseSensors(env)) }
        if bench {
            o.command = .bench
            o.benchSensor = sensorArg
        } else if let command {
            o.command = command
        } else if let sensorArg {
            o.command = .sensor(sensorArg)
        }
        if o.page != nil, !o.modeGiven { o.mode = .interactive }
        return o
    }

    static func parseSensors(_ s: String) throws(ParseError) -> Set<SensorID> {
        if s == "all" { return Set(SensorID.allCases) }
        var out: Set<SensorID> = []
        for part in s.split(separator: ",") {
            let name = part.trimmingCharacters(in: .whitespaces)
            guard let id = SensorID(rawValue: name) else { throw ParseError(description: "unknown sensor \(name)") }
            out.insert(id)
        }
        return out
    }

    static let demandNames: [(String, SamplingDemand)] = [
        ("perCore", .perCore), ("connections", .connections), ("rawTemperatures", .rawTemperatures),
        ("wifi", .wifi), ("smart", .smart), ("volumes", .volumes), ("sleepAssertions", .sleepAssertions),
        ("processTable", .processTable), ("memoryAlert", .memoryAlert),
    ]

    static func parseDemand(_ s: String) throws(ParseError) -> SamplingDemand {
        var d: SamplingDemand = []
        for part in s.split(separator: ",") {
            let name = part.trimmingCharacters(in: .whitespaces)
            if name == "all" {
                for (_, v) in demandNames { d.insert(v) }
                continue
            }
            guard let v = demandNames.first(where: { $0.0 == name })?.1 else {
                throw ParseError(description: "unknown demand \(name)")
            }
            d.insert(v)
        }
        return d
    }

    static func describe(_ d: SamplingDemand) -> String {
        let names = demandNames.filter { d.contains($0.1) }.map(\.0)
        return names.isEmpty ? "none" : names.joined(separator: ",")
    }

    /// Engine visibility for `--record`/`--frames`/`--bench` engine ticks: `--page`, else the page whose demand
    /// covers `--demand` (engine demand only comes from visibility; `.connections` → an inspected app).
    var visibility: UIVisibility {
        Self.visibility(page: page, demand: demand, mode: mode)
    }

    static func visibility(page: DashboardPage?, demand: SamplingDemand, mode: SamplingMode) -> UIVisibility {
        let inspected: AppKey? = demand.contains(.connections) ? .other : nil
        if let page { return UIVisibility(dashboardVisible: true, page: page, inspectedApp: inspected) }
        let wanted = demand.subtracting([.connections, .memoryAlert])
        if !wanted.isEmpty {
            // First page by overlap with the requested demand (a page carries one demand set).
            let best = DashboardPage.allCases.max { a, b in
                UIVisibility(dashboardVisible: true, page: a).demand.intersection(wanted).rawValue.nonzeroBitCount
                    < UIVisibility(dashboardVisible: true, page: b).demand.intersection(wanted).rawValue.nonzeroBitCount
            }
            return UIVisibility(dashboardVisible: true, page: best, inspectedApp: inspected)
        }
        if inspected != nil { return UIVisibility(dashboardVisible: true, page: .processes, inspectedApp: inspected) }
        return mode == .interactive ? UIVisibility(popoverOpen: true) : UIVisibility()
    }
}
