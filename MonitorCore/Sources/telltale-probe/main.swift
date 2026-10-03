import Foundation
import MonitorModel

// telltale-probe (W7 T2): sensors, engine and store from the command line. See ProbeOptions.usage.
setvbuf(stdout, nil, _IOLBF, 0)

let options: ProbeOptions
do {
    options = try ProbeOptions.parse(Array(CommandLine.arguments.dropFirst()), env: ProcessInfo.processInfo.environment)
} catch {
    print("telltale-probe: \(error)\n")
    print(ProbeOptions.usage)
    exit(2)
}
if !options.disabled.isEmpty {
    print("disabled: \(options.disabled.map(\.rawValue).sorted().joined(separator: ","))")
}

switch options.command {
case .help: print(ProbeOptions.usage)
case .list: Commands.list(options)
case .sensor(let id): await Commands.sensor(id, options)
case .bench: await Commands.bench(options)
case .record(let path): await Commands.record(to: path, options)
case .replay(let path): Commands.replay(path, options)
case .frames: await Commands.frames(options)
case .maintainNow: await Commands.maintainNow(options)
case .crash(let id): await Commands.crash(id, options)
case .brightness: Commands.brightness()
}
