import Foundation
import MonitorLive
import MonitorModel
import Observation

// DESIGN §3.12 Processes table: Apps/Processes toggle, sort by column, live search, app → process expansion
// (incl. synthetic coalition rows and a "+N restricted" summary), owner-based action enablement.
// `build` is pure (tested); `ProcessTableModel` caches its output and rebuilds once per frame / input change.

/// Sort-by columns (DESIGN §3.12 toolbar "Sort by" and the numeric headers).
public enum ProcessColumn: String, CaseIterable, Sendable {
    case cpu, gpu, memory, network, disk, energy

    public var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "Memory"
        case .network: "Network"
        case .disk: "Disk"
        case .energy: "Energy"
        }
    }
}

/// Stable row identity. `restricted` is the "+N restricted" summary line under an expanded group.
public enum ProcessRowID: Hashable, Sendable {
    case app(AppKey)
    case process(ProcessID)
    case restricted(AppKey)

    public init(_ selection: NavigationModel.ProcessSelection) {
        switch selection {
        case .app(let k): self = .app(k)
        case .process(let p): self = .process(p)
        }
    }

    /// The navigation selection for this row (nil for the summary line, which is not selectable).
    public var selection: NavigationModel.ProcessSelection? {
        switch self {
        case .app(let k): .app(k)
        case .process(let p): .process(p)
        case .restricted: nil
        }
    }
}

/// Per-cell tooltip for "—" values (`unavailableReason`, ARCHITECTURE §5.5); nil = idle or has a value.
public struct ProcessCellReasons: Equatable, Sendable {
    public var cpu: String?
    public var gpu: String?
    public var memory: String?
    public var network: String?
    public var disk: String?
    public var energy: String?

    public init(cpu: String? = nil, gpu: String? = nil, memory: String? = nil, network: String? = nil,
                disk: String? = nil, energy: String? = nil) {
        self.cpu = cpu
        self.gpu = gpu
        self.memory = memory
        self.network = network
        self.disk = disk
        self.energy = energy
    }

    public subscript(_ c: ProcessColumn) -> String? {
        switch c {
        case .cpu: cpu
        case .gpu: gpu
        case .memory: memory
        case .network: network
        case .disk: disk
        case .energy: energy
        }
    }
}

/// One table line (app group, process, or the restricted summary).
public struct ProcessRow: Identifiable, Equatable, Sendable {
    public enum RowKind: Equatable, Sendable { case app, process, restrictedSummary }

    public var id: ProcessRowID
    public var rowKind: RowKind
    public var depth: Int
    public var parity: Int
    public var name: String
    /// "App", "System", "Background"; Apps mode "App · 7 processes". Hidden on child rows.
    public var kindLabel: String?
    public var identity: AppIdentity?
    /// Responsible PID for a group; nil for synthetic rows ("—").
    public var pid: Int32?
    public var user: String?
    public var uid: UInt32?
    public var provenance: Provenance
    public var cpu: Double?
    public var gpu: Double?
    public var memory: UInt64?
    public var network: Double?
    public var disk: Double?
    public var energy: Double?
    public var reasons: ProcessCellReasons
    public var cpuEstimated: Bool
    public var energyEstimated: Bool
    public var hasChildren: Bool
    public var isExpanded: Bool
    public var processCount: Int
    public var threads: Int32?
    public var path: String?
    /// The group this row belongs to (itself for app rows).
    public var appKey: AppKey
    /// Owner rule: every member owned by the current user (and none synthetic).
    public var ownedByCurrentUser: Bool
    /// Owner shown when not owned ("root", "_windowserver").
    public var foreignOwner: String?
    /// Action target; nil for synthetic rows and the summary line.
    public var target: ProcessTarget?

    public func value(_ c: ProcessColumn) -> Double? {
        switch c {
        case .cpu: cpu
        case .gpu: gpu
        case .memory: memory.map(Double.init)
        case .network: network
        case .disk: disk
        case .energy: energy
        }
    }
}

public struct ProcessTableInput: Equatable, Sendable {
    public var processes: [ProcessSample]
    public var apps: [AppSample]
    public var health: [SensorID: SensorStatus]
    public var mode: NavigationModel.ProcessesMode
    public var sort: ProcessColumn
    public var descending: Bool
    public var query: String
    public var expanded: Set<AppKey>
    /// Total shown in the count label ("612 processes"): `cpu.processCount ?? processes.count`.
    public var processCount: Int

    public init(processes: [ProcessSample], apps: [AppSample], health: [SensorID: SensorStatus] = [:],
                mode: NavigationModel.ProcessesMode = .apps, sort: ProcessColumn = .cpu, descending: Bool = true,
                query: String = "", expanded: Set<AppKey> = [], processCount: Int? = nil) {
        self.processes = processes
        self.apps = apps
        self.health = health
        self.mode = mode
        self.sort = sort
        self.descending = descending
        self.query = query
        self.expanded = expanded
        self.processCount = processCount ?? processes.count
    }
}

public struct ProcessTableOutput: Equatable, Sendable {
    public var lines: [ProcessRow] = []
    /// Rows by id, including collapsed children (selection lookup).
    public var index: [ProcessRowID: ProcessRow] = [:]
    /// "{n} apps · 612 processes" / "{n} of 612 shown".
    public var countLabel: String = ""
    /// DESIGN §3.15 empty table copy.
    public var emptyMessage: String = "No processes"
    /// App key → responsible (main) process id, for mode switches.
    public var responsible: [AppKey: ProcessID] = [:]
    /// Process id → its group.
    public var appOf: [ProcessID: AppKey] = [:]
}

/// Quit / Force Quit enablement (DESIGN §2.25, §3.12: disabled for root and other users, tooltip "Owned by {user}").
public struct ProcessActionAvailability: Equatable, Sendable {
    public var canQuit: Bool
    public var canForceQuit: Bool
    public var disabledHelp: String?

    public init(canQuit: Bool, canForceQuit: Bool, disabledHelp: String?) {
        self.canQuit = canQuit
        self.canForceQuit = canForceQuit
        self.disabledHelp = disabledHelp
    }
}

@MainActor @Observable
public final class ProcessTableModel {
    public var sort: ProcessColumn = .cpu { didSet { if sort != oldValue { rebuild() } } }
    public var descending = true { didSet { if descending != oldValue { rebuild() } } }
    public var query = "" { didSet { if query != oldValue { rebuild() } } }
    public private(set) var expanded: Set<AppKey> = []
    /// Not observed: views call `update(from:mode:)` in `body` (it reads the tracked `appsVersion`), so the
    /// rebuild happens lazily once per frame without invalidating the view that triggered it.
    @ObservationIgnored public private(set) var output = ProcessTableOutput()
    /// Rebuild counter (tests; ARCHITECTURE §7 "sort/filter once per frame").
    @ObservationIgnored public private(set) var buildCount = 0

    @ObservationIgnored private var processes: [ProcessSample] = []
    @ObservationIgnored private var apps: [AppSample] = []
    @ObservationIgnored private var health: [SensorID: SensorStatus] = [:]
    @ObservationIgnored private var processCount = 0
    @ObservationIgnored private var mode: NavigationModel.ProcessesMode = .apps
    @ObservationIgnored private var liveVersion: (ObjectIdentifier, Int)?
    @ObservationIgnored private var loaded = false

    public init() {}

    public var lines: [ProcessRow] { output.lines }
    public var countLabel: String { output.countLabel }

    /// Feeds one frame. Rebuilds only when something changed.
    public func update(processes: [ProcessSample], apps: [AppSample], health: [SensorID: SensorStatus],
                       processCount: Int?, mode: NavigationModel.ProcessesMode) {
        let count = processCount ?? processes.count
        if loaded, mode == self.mode, count == self.processCount, health == self.health,
           processes == self.processes, apps == self.apps { return }
        self.processes = processes
        self.apps = apps
        self.health = health
        self.processCount = count
        self.mode = mode
        loaded = true
        rebuild()
    }

    /// Feeds the live model; skipped when `appsVersion` and mode are unchanged (no array comparison).
    public func update(from live: LiveModel, mode: NavigationModel.ProcessesMode) {
        let version = (ObjectIdentifier(live), live.appsVersion)
        if loaded, let v = liveVersion, v.0 == version.0, v.1 == version.1, mode == self.mode,
           live.sensorHealth == health { return }
        liveVersion = version
        processes = live.processes
        apps = live.apps
        health = live.sensorHealth
        processCount = live.cpu.processCount ?? live.processes.count
        self.mode = mode
        loaded = true
        rebuild()
    }

    public func toggleExpanded(_ key: AppKey) { setExpanded(key, !expanded.contains(key)) }

    public func setExpanded(_ key: AppKey, _ open: Bool) {
        guard output.index[.app(key)]?.hasChildren == true else { return }
        if open { expanded.insert(key) } else { expanded.remove(key) }
        rebuild()
    }

    public func row(for selection: NavigationModel.ProcessSelection?) -> ProcessRow? {
        selection.flatMap { output.index[ProcessRowID($0)] }
    }

    /// The selection if its row still exists (survives refresh/reorder), else nil.
    public func validated(_ selection: NavigationModel.ProcessSelection?) -> NavigationModel.ProcessSelection? {
        row(for: selection) == nil ? nil : selection
    }

    /// ↑/↓ over the visible, selectable lines.
    public func moved(_ selection: NavigationModel.ProcessSelection?, by delta: Int) -> NavigationModel.ProcessSelection? {
        let ids = output.lines.compactMap(\.id.selection)
        guard !ids.isEmpty else { return selection }
        guard let selection, let i = ids.firstIndex(of: selection) else { return delta > 0 ? ids.first : ids.last }
        return ids[min(max(i + delta, 0), ids.count - 1)]
    }

    /// Apps → Processes selects the app's responsible process; Processes → Apps selects the process's app.
    public func selection(_ selection: NavigationModel.ProcessSelection?,
                          convertedTo mode: NavigationModel.ProcessesMode) -> NavigationModel.ProcessSelection? {
        switch (selection, mode) {
        case (.app(let k)?, .processes): output.responsible[k].map { .process($0) }
        case (.process(let p)?, .apps): output.appOf[p].map { .app($0) }
        default: selection
        }
    }

    private func rebuild() {
        buildCount += 1
        output = Self.build(ProcessTableInput(processes: processes, apps: apps, health: health, mode: mode, sort: sort,
                                              descending: descending, query: query, expanded: expanded,
                                              processCount: processCount))
    }
}

// MARK: - Pure build

public extension ProcessTableModel {
    nonisolated static let coalitionMemoryReason = "Requires root · updated when Processes is open"
    private nonisolated static let systemNames: Set<String> = ["kernel_task", "launchd", "WindowServer", "loginwindow"]

    nonisolated static func build(_ input: ProcessTableInput) -> ProcessTableOutput {
        var out = ProcessTableOutput()
        var members: [AppKey: [ProcessSample]] = [:]
        for p in input.processes { members[p.app, default: []].append(p) }
        for p in input.processes { out.appOf[p.id] = p.app }
        var responsible: [AppKey: ProcessSample] = [:]
        for (key, ms) in members {
            if let r = responsibleProcess(key: key, members: ms, bundlePath: nil) { responsible[key] = r }
        }
        for app in input.apps {
            if let ms = members[app.identity.key],
               let r = responsibleProcess(key: app.identity.key, members: ms, bundlePath: app.identity.bundlePath) {
                responsible[app.identity.key] = r
            }
        }
        out.responsible = responsible.mapValues(\.id)

        let query = input.query.trimmingCharacters(in: .whitespaces).lowercased()
        func matches(_ p: ProcessSample) -> Bool {
            p.name.lowercased().contains(query) || String(p.pid).contains(query)
                || p.app.id.lowercased().contains(query)
        }

        switch input.mode {
        case .apps:
            var rows: [(ProcessRow, [ProcessRow])] = []
            for app in input.apps where app.identity.key != .other {
                let key = app.identity.key
                let ms = members[key] ?? []
                if !query.isEmpty {
                    let hit = app.identity.displayName.lowercased().contains(query)
                        || key.id.lowercased().contains(query) || ms.contains(where: matches)
                    if !hit { continue }
                }
                let visible = ms.filter { $0.provenance != .restricted }
                let hidden = max(app.hiddenProcessCount, ms.count - visible.count)
                var row = appRow(app, members: ms, responsible: responsible[key], health: input.health)
                row.hasChildren = visible.count > 1 || hidden > 0
                var kids = visible.map { processRow($0, responsibleID: responsible[$0.app]?.id, health: input.health) }
                kids = sorted(kids, by: input.sort, descending: input.descending)
                if hidden > 0 {
                    kids.append(summaryRow(key: key, hidden: hidden, identity: app.identity))
                }
                rows.append((row, row.hasChildren ? kids : []))
            }
            let tops = sorted(rows.map(\.0), by: input.sort, descending: input.descending)
            let kidsByKey = Dictionary(rows.map { ($0.0.appKey, $0.1) }, uniquingKeysWith: { a, _ in a })
            for (i, var top) in tops.enumerated() {
                let open = top.hasChildren && input.expanded.contains(top.appKey)
                top.parity = i % 2
                top.isExpanded = open
                out.lines.append(top)
                out.index[top.id] = top
                for var kid in kidsByKey[top.appKey] ?? [] {
                    kid.depth = 1
                    kid.parity = i % 2
                    kid.kindLabel = kid.rowKind == .restrictedSummary ? nil : kid.kindLabel
                    out.index[kid.id] = kid
                    if open { out.lines.append(kid) }
                }
            }
            // Children of groups filtered out by search still resolve for selection.
            for p in input.processes where out.index[.process(p.id)] == nil {
                out.index[.process(p.id)] = processRow(p, responsibleID: responsible[p.app]?.id, health: input.health)
            }
            out.countLabel = "\(tops.count.formatted()) apps · \(input.processCount.formatted()) processes"
        case .processes:
            var rows: [ProcessRow] = []
            rows.reserveCapacity(input.processes.count)
            for p in input.processes {
                let r = processRow(p, responsibleID: responsible[p.app]?.id, health: input.health)
                out.index[r.id] = r
                if query.isEmpty || matches(p) { rows.append(r) }
            }
            rows = sorted(rows, by: input.sort, descending: input.descending)
            for i in rows.indices { rows[i].parity = i % 2 }
            out.lines = rows
            for app in input.apps where app.identity.key != .other {
                out.index[.app(app.identity.key)] = appRow(app, members: members[app.identity.key] ?? [],
                                                           responsible: responsible[app.identity.key],
                                                           health: input.health)
            }
            out.countLabel = "\(rows.count.formatted()) of \(input.processCount.formatted()) shown"
        }
        out.emptyMessage = query.isEmpty ? "No processes" : "No processes match “\(input.query.trimmingCharacters(in: .whitespaces))”"
        return out
    }

    /// DESIGN §2.25 / §3.12: Quit/Force Quit only when every member is owned by the current user (and the
    /// injected service agrees); otherwise disabled with "Owned by {user}".
    nonisolated static func availability(for row: ProcessRow, serviceCanControl: Bool) -> ProcessActionAvailability {
        guard row.target != nil, row.ownedByCurrentUser else {
            return ProcessActionAvailability(canQuit: false, canForceQuit: false,
                                             disabledHelp: "Owned by \(row.foreignOwner ?? row.user ?? "root")")
        }
        return ProcessActionAvailability(canQuit: serviceCanControl, canForceQuit: serviceCanControl,
                                         disabledHelp: serviceCanControl ? nil : "Not permitted")
    }

    /// Stable order: value (nil last), then name, then id.
    nonisolated static func sorted(_ rows: [ProcessRow], by column: ProcessColumn, descending: Bool) -> [ProcessRow] {
        rows.enumerated().sorted { a, b in
            let x = a.element.value(column).flatMap { $0.isFinite ? $0 : nil }
            let y = b.element.value(column).flatMap { $0.isFinite ? $0 : nil }
            switch (x, y) {
            case let (x?, y?) where x != y: return descending ? x > y : x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default:
                let n = a.element.name.localizedStandardCompare(b.element.name)
                if n != .orderedSame { return n == .orderedAscending }
                return a.offset < b.offset
            }
        }.map(\.element)
    }

    // MARK: Row builders

    private nonisolated static func responsibleProcess(key: AppKey, members: [ProcessSample],
                                                       bundlePath: String?) -> ProcessSample? {
        let real = members.filter { !$0.id.isSynthetic && $0.provenance != .restricted }
        if key.kind == .app {
            let bundle = bundlePath.map(trimmedBundle) ?? real.compactMap(\.path).map(trimmedBundle).first
            if let bundle {
                let main = real.filter { p in
                    guard let path = p.path else { return false }
                    let macOS = bundle + "/Contents/MacOS/"
                    return path.hasPrefix(macOS) && !path.dropFirst(macOS.count).contains("/")
                        && (p.name == (path as NSString).lastPathComponent)
                }
                if let m = main.min(by: { $0.pid < $1.pid }), main.count > 0 {
                    // Prefer the main executable whose name matches the bundle's display name (Docker Desktop
                    // vs com.docker.backend, both in Contents/MacOS).
                    return main.first { p in bundle.hasSuffix("/\(p.name).app") } ?? pickDisplayMatch(main) ?? m
                }
            }
        }
        return real.min { $0.pid < $1.pid } ?? members.first { !$0.id.isSynthetic }
    }

    private nonisolated static func pickDisplayMatch(_ ps: [ProcessSample]) -> ProcessSample? {
        // Helpers are usually reverse-DNS named ("com.docker.backend"); the main binary is not.
        ps.filter { !$0.name.hasPrefix("com.") }.min { $0.pid < $1.pid }
    }

    /// Outermost ".app" of a path ("/Applications/X.app/Contents/MacOS/X" → "/Applications/X.app").
    nonisolated static func trimmedBundle(_ path: String) -> String {
        guard let r = path.range(of: ".app/") else { return path }
        return String(path[..<r.lowerBound]) + ".app"
    }

    private nonisolated static func isSystemProcess(_ p: ProcessSample) -> Bool {
        p.pid == 0 || p.pid == 1 || (p.user?.hasPrefix("_") ?? false) || systemNames.contains(p.name)
    }

    private nonisolated static func baseKind(key: AppKey, representative: ProcessSample?) -> String {
        switch key.kind {
        case .app: return "App"
        case .system, .other: return "System"
        case .process:
            if let p = representative, p.provenance == .coalition || p.id.isSynthetic { return "System" }
            return representative.map(isSystemProcess) == true ? "System" : "Background"
        }
    }

    private nonisolated static func processKind(_ p: ProcessSample, responsibleID: ProcessID?) -> String {
        if p.provenance == .coalition || p.id.isSynthetic { return "System" }
        switch p.app.kind {
        case .app: return p.id == responsibleID ? "App" : "Background"
        case .system, .other: return "System"
        case .process: return isSystemProcess(p) ? "System" : "Background"
        }
    }

    private nonisolated static func sum(_ a: Double?, _ b: Double?) -> Double? {
        switch (a, b) {
        case let (x?, y?): x + y
        case let (x?, nil): x
        case let (nil, y?): y
        default: nil
        }
    }

    private nonisolated static func processReasons(_ p: ProcessSample, health: [SensorID: SensorStatus]) -> ProcessCellReasons {
        let measured = p.provenance == .measured
        func rate(_ a: AppMetric, _ b: AppMetric, _ value: Double?) -> String? {
            guard value == nil else { return nil }
            let r = unavailableReason(a, p, health: health) ?? unavailableReason(b, p, health: health)
            // Idle rate cells on readable rows show "—" with no tooltip (DESIGN §3.15).
            return measured && r == processFallback ? nil : r
        }
        var memory = unavailableReason(.memory, p, health: health)
        if p.memory == nil, !measured, memory == nil || memory == processFallback
            || memory == "Appears when the process table is open" {
            memory = coalitionMemoryReason                                  // DESIGN §3.12 copy
        }
        return ProcessCellReasons(
            cpu: unavailableReason(.cpu, p, health: health),
            gpu: unavailableReason(.gpu, p, health: health),
            memory: memory,
            network: rate(.netRx, .netTx, sum(p.netRxBps, p.netTxBps)),
            disk: rate(.diskRead, .diskWrite, sum(p.diskReadBps, p.diskWriteBps)),
            energy: unavailableReason(.energy, p, health: health))
    }

    private nonisolated static let processFallback = "Not available for this process"
    private nonisolated static let appFallback = "Not available for this app"

    private nonisolated static func processRow(_ p: ProcessSample, responsibleID: ProcessID?,
                                               health: [SensorID: SensorStatus]) -> ProcessRow {
        let synthetic = p.id.isSynthetic
        let owned = !synthetic && p.provenance == .measured ? p.isCurrentUser : false
        let target: ProcessTarget? = synthetic ? nil
            : .process(pid: p.pid, name: p.name, path: p.path, uid: p.uid)
        let kind = processKind(p, responsibleID: responsibleID)
        // An app's main process shows its bundle ("/Applications/Final Cut Pro.app", DESIGN §3.12 inspector).
        let displayPath = kind == "App" ? p.path.map(trimmedBundle) : p.path
        return ProcessRow(
            id: .process(p.id), rowKind: .process, depth: 0, parity: 0, name: p.name,
            kindLabel: kind,
            identity: AppIdentity(key: p.app, displayName: p.name, bundlePath: p.path.map(trimmedBundle)),
            pid: synthetic ? nil : p.pid, user: p.user, uid: p.uid, provenance: p.provenance,
            cpu: p.cpuPercent, gpu: p.gpuPercent, memory: p.memory,
            network: sum(p.netRxBps, p.netTxBps), disk: sum(p.diskReadBps, p.diskWriteBps), energy: p.energyWatts,
            reasons: processReasons(p, health: health),
            cpuEstimated: p.provenance == .coalition, energyEstimated: p.energyEstimated,
            hasChildren: false, isExpanded: false, processCount: 1, threads: p.threads, path: displayPath,
            appKey: p.app, ownedByCurrentUser: owned,
            foreignOwner: owned ? nil : (p.user ?? "uid \(p.uid)"), target: target)
    }

    private nonisolated static func appRow(_ app: AppSample, members: [ProcessSample], responsible: ProcessSample?,
                                           health: [SensorID: SensorStatus]) -> ProcessRow {
        let key = app.identity.key
        // Coalition groups (no readable member) are "System" rows (DESIGN §3.12 rule 3).
        let coalitionOnly = !members.isEmpty && members.allSatisfy { $0.provenance != .measured }
        let base = coalitionOnly ? "System" : baseKind(key: key, representative: responsible ?? members.first)
        let count = max(app.processIDs.count, members.count)
        let real = members.filter { !$0.id.isSynthetic }
        let foreign = members.first { !$0.isCurrentUser || $0.provenance != .measured }
        let owned = !real.isEmpty && foreign == nil
        func rate(_ a: AppMetric, _ b: AppMetric, _ value: Double?) -> String? {
            guard value == nil else { return nil }
            let r = unavailableReason(a, app, health: health) ?? unavailableReason(b, app, health: health)
            return r == appFallback ? nil : r
        }
        var reasons = ProcessCellReasons(
            cpu: unavailableReason(.cpu, app, health: health),
            gpu: unavailableReason(.gpu, app, health: health),
            memory: unavailableReason(.memory, app, health: health),
            network: rate(.netRx, .netTx, sum(app.netRxBps, app.netTxBps)),
            disk: rate(.diskRead, .diskWrite, sum(app.diskReadBps, app.diskWriteBps)),
            energy: unavailableReason(.energy, app, health: health))
        if app.memory == nil, members.contains(where: { $0.provenance != .measured }),
           reasons.memory == nil || reasons.memory == appFallback || reasons.memory?.hasPrefix("Owned by") == true {
            reasons.memory = coalitionMemoryReason
        }
        let path = app.identity.bundlePath.map(trimmedBundle) ?? responsible?.path
        return ProcessRow(
            id: .app(key), rowKind: .app, depth: 0, parity: 0, name: app.identity.displayName,
            kindLabel: count > 1 ? "\(base) · \(count.formatted()) processes" : base,
            identity: AppIdentity(key: key, displayName: app.identity.displayName, bundlePath: path),
            pid: responsible?.pid, user: responsible?.user ?? members.first?.user,
            uid: responsible?.uid ?? members.first?.uid,
            provenance: members.allSatisfy { $0.provenance != .measured } && !members.isEmpty ? .coalition : .measured,
            cpu: app.cpuPercent, gpu: app.gpuPercent, memory: app.memory,
            network: sum(app.netRxBps, app.netTxBps), disk: sum(app.diskReadBps, app.diskWriteBps),
            energy: app.energyWatts, reasons: reasons,
            cpuEstimated: members.contains { $0.provenance == .coalition }, energyEstimated: app.energyEstimated,
            hasChildren: false, isExpanded: false, processCount: count, threads: app.threads, path: path,
            appKey: key, ownedByCurrentUser: owned,
            foreignOwner: owned ? nil : (foreign?.user ?? responsible?.user ?? "another user"),
            target: real.isEmpty ? nil
                : .app(AppIdentity(key: key, displayName: app.identity.displayName, bundlePath: path),
                       pids: real.map(\.pid).sorted()))
    }

    private nonisolated static func summaryRow(key: AppKey, hidden: Int, identity: AppIdentity) -> ProcessRow {
        ProcessRow(
            id: .restricted(key), rowKind: .restrictedSummary, depth: 1, parity: 0,
            name: "+\(hidden.formatted()) restricted", kindLabel: nil, identity: nil, pid: nil, user: nil, uid: nil,
            provenance: .restricted, cpu: nil, gpu: nil, memory: nil, network: nil, disk: nil, energy: nil,
            reasons: ProcessCellReasons(), cpuEstimated: false, energyEstimated: false, hasChildren: false,
            isExpanded: false, processCount: hidden, threads: nil, path: nil, appKey: key,
            ownedByCurrentUser: false, foreignOwner: nil, target: nil)
    }
}
