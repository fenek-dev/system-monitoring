import Foundation
import MonitorModel

/// One demo application, with baseline metrics reproducing the design artboards' cited numbers
/// (DESIGN.md §3.1 popover top consumer, §3.4 Overview top-processes row, §3.5 CPU top-consumers row,
/// §3.12 Processes inspector example). Each app gets its own small `DemoSeries` for gentle cpu jitter;
/// other fields stay close to baseline (a mock does not need every column to visibly animate).
struct DemoApp {
    var key: AppKey
    var displayName: String
    var bundlePath: String?
    var pid: Int32
    var user: String?
    var isCurrentUser: Bool
    var threads: Int32
    var cpuTimeNs: UInt64
    var provenance: Provenance
    var baseCPU: Double
    var baseGPU: Double
    var memoryBytes: UInt64
    var netRxBps: Double
    var netTxBps: Double
    var diskReadBps: Double
    var diskWriteBps: Double
    var energyWatts: Double
    var jitterSeed: UInt32
}

enum DemoApps {
    private static func gb(_ v: Double) -> UInt64 { UInt64(v * 1_073_741_824) }
    private static func mb(_ v: Double) -> UInt64 { UInt64(v * 1_048_576) }
    private static func kbs(_ v: Double) -> Double { v * 1_024 }

    /// The standing roster (DESIGN §3: Xcode, Final Cut Pro, Safari, WindowServer, Docker Desktop
    /// [+ its `com.docker.backend` helper], Dropbox, Slack, Music, mds_stores).
    static func roster(scenario: MockScenario) -> [DemoApp] {
        // Final Cut Pro is the thermal culprit: GPU climbs from its calm 9.2% baseline (DESIGN §3.12
        // inspector example) toward the alert detail "96% CPU · 41% GPU" (DESIGN §3.2).
        let (fcpCPU, fcpGPU): (Double, Double) =
            switch scenario {
            case .thermalFair: (96.4, 41)
            case .thermalCritical: (98.2, 55)
            default: (96.1, 9.2)
            }
        // Docker Desktop's backend is the memory culprit (History.dc.html: "Docker Desktop · 6.2 GB memory").
        let dockerBackendMemGB: Double =
            switch scenario {
            case .memoryWarning: 6.2
            case .memoryCritical: 9.4
            default: 1.2
            }
        // A stuck build: ≥ 100 % CPU sustained (AlertConfig.runawayEnterCPUPercent), per the `runaway` scenario.
        let xcodeCPU: Double = scenario == .runaway ? 340 : 212.4

        return [
            DemoApp(
                key: AppKey(kind: .app, id: "com.apple.dt.Xcode"), displayName: "Xcode",
                bundlePath: "/Applications/Xcode.app", pid: 1842, user: "arthur", isCurrentUser: true,
                threads: 86, cpuTimeNs: (2 * 3_600 + 41 * 60 + 7) * 1_000_000_000,
                provenance: .measured, baseCPU: xcodeCPU, baseGPU: 0.4, memoryBytes: gb(3.82),
                netRxBps: 0, netTxBps: 0, diskReadBps: kbs(80), diskWriteBps: kbs(220),
                energyWatts: 4.82, jitterSeed: 1101
            ),
            DemoApp(
                key: AppKey(kind: .app, id: "com.apple.FinalCut"), displayName: "Final Cut Pro",
                bundlePath: "/Applications/Final Cut Pro.app", pid: 2210, user: "arthur", isCurrentUser: true,
                threads: 64, cpuTimeNs: (1 * 3_600 + 12 * 60 + 30) * 1_000_000_000,
                provenance: .measured, baseCPU: fcpCPU, baseGPU: fcpGPU, memoryBytes: gb(5.10),
                netRxBps: 0, netTxBps: 0, diskReadBps: kbs(320), diskWriteBps: kbs(9_400),
                energyWatts: 7.15, jitterSeed: 1102
            ),
            DemoApp(
                key: AppKey(kind: .app, id: "com.apple.Safari"), displayName: "Safari",
                bundlePath: "/Applications/Safari.app", pid: 967, user: "arthur", isCurrentUser: true,
                threads: 18, cpuTimeNs: 34 * 60 * 1_000_000_000,
                provenance: .measured, baseCPU: 14, baseGPU: 1.1, memoryBytes: mb(780),
                netRxBps: kbs(45), netTxBps: kbs(8), diskReadBps: kbs(12), diskWriteBps: kbs(4),
                energyWatts: 0.35, jitterSeed: 1103
            ),
            DemoApp(
                key: AppKey(kind: .process, id: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer"),
                displayName: "WindowServer", bundlePath: nil, pid: 210, user: "_windowserver", isCurrentUser: false,
                threads: 12, cpuTimeNs: 6 * 3_600 * 1_000_000_000,
                provenance: .measured, baseCPU: 6.5, baseGPU: 2.0, memoryBytes: mb(420),
                netRxBps: 0, netTxBps: 0, diskReadBps: 0, diskWriteBps: 0,
                energyWatts: 0.6, jitterSeed: 1104
            ),
            DemoApp(
                key: AppKey(kind: .app, id: "com.docker.docker"), displayName: "Docker Desktop",
                bundlePath: "/Applications/Docker.app", pid: 501, user: "arthur", isCurrentUser: true,
                threads: 20, cpuTimeNs: 3 * 3_600 * 1_000_000_000,
                provenance: .measured, baseCPU: 3.1, baseGPU: 0, memoryBytes: mb(310),
                netRxBps: kbs(6), netTxBps: kbs(2), diskReadBps: kbs(40), diskWriteBps: kbs(60),
                energyWatts: 0.22, jitterSeed: 1105
            ),
            // Its own row in Processes mode (Processes.dc.html lists "com.docker.backend" by name); groups
            // under "Docker Desktop" in Apps mode via `DemoApps.group`, which names the group after the
            // first member (the main process above).
            DemoApp(
                key: AppKey(kind: .app, id: "com.docker.docker"), displayName: "com.docker.backend",
                bundlePath: "/Applications/Docker.app", pid: 502, user: "arthur", isCurrentUser: true,
                threads: 35, cpuTimeNs: 3 * 3_600 * 1_000_000_000,
                provenance: .measured, baseCPU: 9.8, baseGPU: 0, memoryBytes: gb(dockerBackendMemGB),
                netRxBps: kbs(3), netTxBps: kbs(1), diskReadBps: kbs(90), diskWriteBps: kbs(140),
                energyWatts: 0.41, jitterSeed: 1106
            ),
            DemoApp(
                key: AppKey(kind: .app, id: "com.getdropbox.dropbox"), displayName: "Dropbox",
                bundlePath: "/Applications/Dropbox.app", pid: 703, user: "arthur", isCurrentUser: true,
                threads: 14, cpuTimeNs: 5 * 3_600 * 1_000_000_000,
                provenance: .measured, baseCPU: 2.4, baseGPU: 0, memoryBytes: mb(340),
                netRxBps: kbs(180), netTxBps: kbs(20), diskReadBps: kbs(30), diskWriteBps: kbs(90),
                energyWatts: 0.18, jitterSeed: 1107
            ),
            DemoApp(
                key: AppKey(kind: .app, id: "com.tinyspeck.slackmacgap"), displayName: "Slack",
                bundlePath: "/Applications/Slack.app", pid: 754, user: "arthur", isCurrentUser: true,
                threads: 22, cpuTimeNs: 4 * 3_600 * 1_000_000_000,
                provenance: .measured, baseCPU: 3.0, baseGPU: 0.2, memoryBytes: mb(410),
                netRxBps: kbs(9), netTxBps: kbs(3), diskReadBps: kbs(4), diskWriteBps: kbs(4),
                energyWatts: 0.14, jitterSeed: 1108
            ),
            DemoApp(
                key: AppKey(kind: .app, id: "com.apple.Music"), displayName: "Music",
                bundlePath: "/System/Applications/Music.app", pid: 812, user: "arthur", isCurrentUser: true,
                threads: 9, cpuTimeNs: 2 * 3_600 * 1_000_000_000,
                provenance: .measured, baseCPU: 1.2, baseGPU: 0, memoryBytes: mb(180),
                netRxBps: kbs(2), netTxBps: 0, diskReadBps: kbs(2), diskWriteBps: 0,
                energyWatts: 0.05, jitterSeed: 1109
            ),
            DemoApp(
                key: AppKey(kind: .process, id: "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/Metadata.framework/Support/mds_stores"),
                displayName: "mds_stores", bundlePath: nil, pid: 118, user: "root", isCurrentUser: false,
                threads: 6, cpuTimeNs: 40 * 60 * 1_000_000_000,
                provenance: .measured, baseCPU: 1.5, baseGPU: 0, memoryBytes: mb(85),
                netRxBps: 0, netTxBps: 0, diskReadBps: kbs(6), diskWriteBps: kbs(6),
                energyWatts: 0.03, jitterSeed: 1110
            ),
        ]
    }

    /// Many more small apps (`many-apps`, part of `.restricted`): generic App Store-style utilities.
    static func extraApps(count: Int, seedOffset: UInt64) -> [DemoApp] {
        let stems = ["Grammarly", "Rectangle", "Notion", "Figma", "1Password", "Postman", "iTerm2",
                     "Alfred", "CleanMyMac", "Spotify", "Zoom", "Discord", "VLC", "Obsidian", "Docker Compose UI"]
        var apps: [DemoApp] = []
        apps.reserveCapacity(count)
        for i in 0..<count {
            let name = "\(stems[i % stems.count])\(i / stems.count > 0 ? " \(i / stems.count + 1)" : "")"
            var rng = DemoLCG(seed: UInt32(truncatingIfNeeded: seedOffset &+ UInt64(i) &* 97))
            let cpu = 0.1 + rng.next() * 2.5
            let memMB = 60.0 + rng.next() * 300
            apps.append(DemoApp(
                key: AppKey(kind: .app, id: "com.demo.\(name.lowercased().replacingOccurrences(of: " ", with: ""))"),
                displayName: name, bundlePath: "/Applications/\(name).app",
                pid: Int32(2_000 + i), user: "arthur", isCurrentUser: true,
                threads: Int32(4 + i % 10), cpuTimeNs: UInt64(60 + i) * 1_000_000_000,
                provenance: .measured, baseCPU: cpu, baseGPU: 0, memoryBytes: mb(memMB),
                netRxBps: 0, netTxBps: 0, diskReadBps: 0, diskWriteBps: 0,
                energyWatts: 0.01, jitterSeed: UInt32(truncatingIfNeeded: 5_000 + i)
            ))
        }
        return apps
    }

    /// `ProcessSample` + `AppSample` for one demo app, evaluated at `tick`. Single-process apps are their
    /// own group; multi-process apps (Docker Desktop) are merged by the caller.
    /// Live flow count (Network "Connections" column): ≈ √(↓+↑ KB/s), at least 1 while the app has traffic,
    /// nil when idle — deterministic, and in the artboard's 3…14 range for the demo roster.
    static func connections(_ app: DemoApp) -> Int? {
        let kb = (app.netRxBps + app.netTxBps) / 1_000
        guard kb > 0 else { return nil }
        return max(1, Int(kb.squareRoot().rounded()))
    }

    static func makeProcess(_ app: DemoApp, at tick: Int) -> ProcessSample {
        let series = DemoSeries(seed: app.jitterSeed, base: app.baseCPU, vol: max(app.baseCPU * 0.06, 0.3),
                                 min: max(app.baseCPU * 0.5, 0), max: app.baseCPU * 1.5 + 5)
        let cpu = series.value(afterTicks: tick)
        return ProcessSample(
            id: ProcessID(pid: app.pid, startTimeUs: 1),
            name: app.displayName,
            path: app.bundlePath.map { "\($0)/Contents/MacOS/\(app.displayName)" },
            user: app.user,
            uid: app.isCurrentUser ? 501 : (app.user == "root" ? 0 : 200),
            isCurrentUser: app.isCurrentUser,
            app: app.key,
            provenance: app.provenance,
            cpuPercent: cpu,
            cpuTimeNs: app.cpuTimeNs + UInt64(max(0, Double(tick))) * 1_000_000_000,
            threads: app.threads,
            memory: app.memoryBytes,
            memorySource: .footprint,
            gpuPercent: app.baseGPU,
            gpuTimeNs: app.cpuTimeNs / 4,
            netRxBps: app.netRxBps > 0 ? app.netRxBps : nil,
            netTxBps: app.netTxBps > 0 ? app.netTxBps : nil,
            netRxTotal: UInt64(app.netRxBps) * UInt64(max(tick, 1)),
            netTxTotal: UInt64(app.netTxBps) * UInt64(max(tick, 1)),
            connectionCount: Self.connections(app),
            diskReadBps: app.diskReadBps > 0 ? app.diskReadBps : nil,
            diskWriteBps: app.diskWriteBps > 0 ? app.diskWriteBps : nil,
            diskReadTotal: UInt64(app.diskReadBps) * UInt64(max(tick, 1)),
            diskWriteTotal: UInt64(app.diskWriteBps) * UInt64(max(tick, 1)),
            energyWatts: app.energyWatts,
            energyEstimated: false,
            preventsSleep: false,
            diskReadSession: UInt64(app.diskReadBps) * UInt64(max(tick, 1)),     // ICR-14: the mock session = its total
            diskWriteSession: UInt64(app.diskWriteBps) * UInt64(max(tick, 1))
        )
    }

    /// Groups processes into `AppSample`s (ARCHITECTURE §5.1: one row per `AppKey`, summed), sorted by
    /// `cpuPercent` desc per `SystemFrame.apps`'s contract.
    static func group(_ processes: [ProcessSample]) -> [AppSample] {
        var order: [AppKey] = []
        var byKey: [AppKey: [ProcessSample]] = [:]
        for p in processes {
            if byKey[p.app] == nil { order.append(p.app) }
            byKey[p.app, default: []].append(p)
        }
        return order.map { key in
            let members = byKey[key] ?? []
            let restricted = members.filter { $0.provenance == .restricted }
            let sample = AppSample(
                identity: AppIdentity(key: key, displayName: members.first?.name ?? key.id,
                                       bundlePath: members.first?.path),
                processIDs: members.map(\.id),
                hiddenProcessCount: restricted.count,
                isCurrentUser: members.contains { $0.isCurrentUser },
                cpuPercent: sum(members.map(\.cpuPercent)),
                gpuPercent: sum(members.map(\.gpuPercent)),
                memory: sumBytes(members.map(\.memory)),
                netRxBps: sum(members.map(\.netRxBps)),
                netTxBps: sum(members.map(\.netTxBps)),
                diskReadBps: sum(members.map(\.diskReadBps)),
                diskWriteBps: sum(members.map(\.diskWriteBps)),
                energyWatts: sum(members.map(\.energyWatts)),
                energyEstimated: members.contains { $0.provenance != .measured },
                cpuTimeNs: members.compactMap(\.cpuTimeNs).reduce(0, +),
                gpuTimeNs: members.compactMap(\.gpuTimeNs).reduce(0, +),
                netRxSession: members.compactMap(\.netRxTotal).reduce(0, +),
                netTxSession: members.compactMap(\.netTxTotal).reduce(0, +),
                threads: members.compactMap(\.threads).reduce(0, +),
                connectionCount: members.contains { $0.connectionCount != nil }
                    ? members.compactMap(\.connectionCount).reduce(0, +) : nil,
                preventsSleep: members.contains(where: \.preventsSleep),
                diskReadSession: members.compactMap(\.diskReadSession).reduce(0, +),     // ICR-14
                diskWriteSession: members.compactMap(\.diskWriteSession).reduce(0, +)
            )
            return sample
        }
        .sorted { ($0.cpuPercent ?? -1) > ($1.cpuPercent ?? -1) }
    }

    private static func sum(_ values: [Double?]) -> Double? {
        let present = values.compactMap { $0 }
        return present.isEmpty ? nil : present.reduce(0, +)
    }

    private static func sumBytes(_ values: [UInt64?]) -> UInt64? {
        let present = values.compactMap { $0 }
        return present.isEmpty ? nil : present.reduce(0, +)
    }
}
