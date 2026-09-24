import Darwin
import Foundation
import MonitorLive
import MonitorModel
import MonitorUIKit
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

    /// Total order used as the last sort tiebreak (apps by key, processes by pid then start time).
    public func precedes(_ other: ProcessRowID) -> Bool {
        switch (self, other) {
        case let (.process(a), .process(b)):
            return a.pid != b.pid ? a.pid < b.pid : a.startTimeUs < b.startTimeUs
        case let (.app(a), .app(b)), let (.restricted(a), .restricted(b)):
            return a.description < b.description
        default:
            return rank < other.rank
        }
    }

    private var rank: Int {
        switch self {
        case .app: 0
        case .process: 1
        case .restricted: 2
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
    /// ICR-13 "Exited processes" row (`ProcessID.exitedResidual`, pid −2): estimated, no actions, no detail, kept
    /// with its app when sorting.
    public var isExitedResidual: Bool = false
    /// The concrete process [Sample] targets (the row's own, or the group's responsible process), with its start
    /// time for the pid-reuse check; nil for synthetic rows.
    public var sampleID: ProcessID?

    public func value(_ c: ProcessColumn) -> Double? {
        switch c {
        case .cpu: cpu
        case .gpu: gpu
        case .memory: memory.map { Double($0) }   // not `Double.init` (resolves to Double(bitPattern:))
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
    /// Optional precomputed name order for sort ties (the model caches it across frames).
    public var nameRank: [String: Int]? = nil

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
    /// Rows built this frame (the lines, plus every app row in Apps mode). Rows that aren't on screen — a collapsed
    /// child, an app while in Processes mode — are built on demand by `row(for:)` (perf: no ~900 hidden rows/tick).
    public var index: [ProcessRowID: ProcessRow] = [:]
    /// "{n} apps · 612 processes" / "{n} of 612 shown".
    public var countLabel: String = ""
    /// DESIGN §3.15 empty table copy.
    public var emptyMessage: String = "No processes"
    /// App key → responsible (main) process id, for mode switches.
    public var responsible: [AppKey: ProcessID] = [:]
    /// Process id → its group.
    public var appOf: [ProcessID: AppKey] = [:]
    /// Inputs for on-demand rows and the owner rule.
    public var processByID: [ProcessID: ProcessSample] = [:]
    public var membersByApp: [AppKey: [ProcessSample]] = [:]
    public var appByKey: [AppKey: AppSample] = [:]
    public var health: [SensorID: SensorStatus] = [:]
}

/// Quit / Force Quit enablement (DESIGN §2.25, §3.12: disabled for root and other users, tooltip "Owned by {user}").
public struct ProcessActionAvailability: Equatable, Sendable {
    public var canQuit: Bool
    public var canForceQuit: Bool
    public var disabledHelp: String?
    /// Telltale itself (DESIGN §2.25): Quit quits Telltale; Force Quit is hidden and never offered.
    public var isSelf: Bool
    /// [Sample]: own-user, not Telltale, a real pid (DESIGN §3.12 "disabled for non-owned processes").
    public var canSample: Bool

    public init(canQuit: Bool, canForceQuit: Bool, disabledHelp: String?, isSelf: Bool = false,
                canSample: Bool = false) {
        self.canQuit = canQuit
        self.canForceQuit = canForceQuit
        self.disabledHelp = disabledHelp
        self.isSelf = isSelf
        self.canSample = canSample
    }
}

@MainActor @Observable
public final class ProcessTableModel {
    public var sort: ProcessColumn = .cpu { didSet { if sort != oldValue { rebuild() } } }
    public var descending = true { didSet { if descending != oldValue { rebuild() } } }
    public var query = "" { didSet { if query != oldValue { rebuild() } } }
    public private(set) var expanded: Set<AppKey> = []
    /// Rebuilt once per frame (`update`, from the page's `onChange(of: appsVersion)`) or input change.
    public private(set) var output = ProcessTableOutput()
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
        guard row(for: .app(key))?.hasChildren == true else { return }
        if open { expanded.insert(key) } else { expanded.remove(key) }
        rebuild()
    }

    public func row(for selection: NavigationModel.ProcessSelection?) -> ProcessRow? {
        guard let selection else { return nil }
        return output.index[ProcessRowID(selection)] ?? Self.row(for: selection, in: output)
    }

    /// The selection if its row still exists (survives refresh/reorder), else nil.
    public func validated(_ selection: NavigationModel.ProcessSelection?) -> NavigationModel.ProcessSelection? {
        row(for: selection) == nil ? nil : selection
    }

    /// ↑/↓ over the visible, selectable lines.
    public func moved(_ selection: NavigationModel.ProcessSelection?, by delta: Int) -> NavigationModel.ProcessSelection? {
        let ids = output.lines.compactMap(\.id.selection)
        guard !ids.isEmpty else { return selection }
        guard let selection else { return delta > 0 ? ids.first : ids.last }
        if let i = ids.firstIndex(of: selection) { return ids[min(max(i + delta, 0), ids.count - 1)] }
        // A child hidden in a collapsed group (or filtered out): step from its visible parent.
        if case .process(let p) = selection, let app = output.appOf[p],
           let i = ids.firstIndex(of: .app(app)) {
            return ids[min(max(i + (delta > 0 ? delta : delta + 1), 0), ids.count - 1)]
        }
        return delta > 0 ? ids.first : ids.last
    }

    /// Targets the owner rule allows (every member owned by the current user, none synthetic). The page ANDs this
    /// into `processActions.canControl` so the row menu and the inspector agree.
    public func ownerAllows(_ target: ProcessTarget) -> Bool {
        switch target {
        case .process(let pid, _, _, _):
            guard let p = output.processByID.values.first(where: { $0.pid == pid }) else { return false }
            return !p.id.isSynthetic && p.provenance == .measured && p.isCurrentUser
        case .app(let identity, _):
            return Self.ownedByCurrentUser(output.membersByApp[identity.key] ?? [])
        }
    }

    /// The app whose connections the engine should sample (ICR-10): the selected row's group, and only while the
    /// inspector detail is expanded.
    public nonisolated static func inspectedApp(row: ProcessRow?, detailExpanded: Bool) -> AppKey? {
        guard detailExpanded, let row, row.rowKind != .restrictedSummary, !row.isExitedResidual else { return nil }
        return row.appKey
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
        refreshNameRank()
        var input = ProcessTableInput(processes: processes, apps: apps, health: health, mode: mode, sort: sort,
                                      descending: descending, query: query, expanded: expanded,
                                      processCount: processCount)
        input.nameRank = nameRank
        output = Self.build(input)
    }

    /// Tie-break order of names (`localizedStandardCompare`), recomputed only when the set of names changes — so the
    /// per-tick sort compares integers instead of running ~n log n localized string compares on value ties.
    @ObservationIgnored private var nameRank: [String: Int] = [:]
    @ObservationIgnored private var rankedNames: Set<String> = []

    private func refreshNameRank() {
        var names = Set<String>()
        names.reserveCapacity(apps.count + processes.count)
        for a in apps { names.insert(a.identity.displayName) }
        for p in processes { names.insert(p.name) }
        guard names != rankedNames else { return }
        rankedNames = names
        let ordered = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        nameRank = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1, $0) })
    }
}

// MARK: - Pure build

public extension ProcessTableModel {
    nonisolated static let coalitionMemoryReason = "Requires root · updated when Processes is open"
    private nonisolated static let systemNames: Set<String> = ["kernel_task", "launchd", "WindowServer", "loginwindow"]

    nonisolated static func build(_ input: ProcessTableInput) -> ProcessTableOutput {
        var out = ProcessTableOutput()
        var members: [AppKey: [ProcessSample]] = [:]
        out.appOf.reserveCapacity(input.processes.count)
        out.processByID.reserveCapacity(input.processes.count)
        for p in input.processes {
            members[p.app, default: []].append(p)
            out.appOf[p.id] = p.app
            out.processByID[p.id] = p
        }
        out.membersByApp = members
        out.health = input.health
        for app in input.apps { out.appByKey[app.identity.key] = app }
        let rank = input.nameRank
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
                let visibleCount = ms.reduce(0) { $0 + ($1.provenance != .restricted ? 1 : 0) }
                let hidden = max(app.hiddenProcessCount, ms.count - visibleCount)
                var row = appRow(app, members: ms, responsible: responsible[key], health: input.health)
                row.hasChildren = visibleCount > 1 || hidden > 0
                // Children are built only for expanded groups (collapsed ones resolve on demand).
                var kids: [ProcessRow] = []
                if row.hasChildren && input.expanded.contains(key) {
                    kids = ms.filter { $0.provenance != .restricted }
                        .map { processRow($0, responsibleID: responsible[$0.app]?.id, health: input.health) }
                    kids = keepingExitedWithApp(sorted(kids, by: input.sort, descending: input.descending, rank: rank))
                    if hidden > 0 {
                        kids.append(summaryRow(key: key, hidden: hidden, identity: app.identity))
                    }
                }
                rows.append((row, kids))
            }
            let tops = sorted(rows.map(\.0), by: input.sort, descending: input.descending, rank: rank)
            let kidsByKey = Dictionary(rows.map { ($0.0.appKey, $0.1) }, uniquingKeysWith: { a, _ in a })
            out.lines.reserveCapacity(tops.count)
            for (i, var top) in tops.enumerated() {
                let open = top.hasChildren && input.expanded.contains(top.appKey)
                top.parity = i % 2
                top.isExpanded = open
                out.lines.append(top)
                out.index[top.id] = top
                guard open else { continue }
                for var kid in kidsByKey[top.appKey] ?? [] {
                    kid.depth = 1
                    kid.parity = i % 2
                    out.index[kid.id] = kid
                    out.lines.append(kid)
                }
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
            rows = keepingExitedWithApp(sorted(rows, by: input.sort, descending: input.descending, rank: rank))
            for i in rows.indices { rows[i].parity = i % 2 }
            out.lines = rows
            out.countLabel = "\(rows.count.formatted()) of \(input.processCount.formatted()) shown"
        }
        out.emptyMessage = query.isEmpty ? "No processes" : "No processes match “\(input.query.trimmingCharacters(in: .whitespaces))”"
        return out
    }

    /// DESIGN §2.25 / §3.12: Quit/Force Quit only when every member is owned by the current user (and the
    /// injected service agrees); otherwise disabled with "Owned by {user}".
    /// The self rule is `TTRowActionsMenu.model(…)`'s (`forceQuitVisible == false` ⇔ Telltale), so menu, inspector and
    /// ⌘⌫ agree.
    nonisolated static func availability(for row: ProcessRow, serviceCanControl: Bool, ownPID: Int32 = getpid(),
                                         ownBundleID: String? = Bundle.main.bundleIdentifier) -> ProcessActionAvailability {
        if let target = row.target {
            let menu = TTRowActionsMenu.model(target: target, canControl: serviceCanControl, hasForceQuitHandler: true,
                                              ownPID: ownPID, ownBundleID: ownBundleID)
            if !menu.forceQuitVisible {
                return ProcessActionAvailability(canQuit: true, canForceQuit: false, disabledHelp: nil, isSelf: true)
            }
        }
        guard row.target != nil, row.ownedByCurrentUser else {
            return ProcessActionAvailability(canQuit: false, canForceQuit: false,
                                             disabledHelp: "Owned by \(row.foreignOwner ?? row.user ?? "root")")
        }
        // Sampling needs no kill permission, only an own-user real pid (not Telltale — handled above).
        let canSample = row.sampleID.map { !$0.isSynthetic && $0.pid > 0 } ?? false
        return ProcessActionAvailability(canQuit: serviceCanControl, canForceQuit: serviceCanControl,
                                         disabledHelp: serviceCanControl ? nil : "Not permitted", canSample: canSample)
    }

    /// Deterministic order independent of input order: value (nil last), then name (`rank` when given, else
    /// `localizedStandardCompare`), then row id (pid). Values are read once per row, not per comparison.
    nonisolated static func sorted(_ rows: [ProcessRow], by column: ProcessColumn, descending: Bool,
                                   rank: [String: Int]? = nil) -> [ProcessRow] {
        let keyed = rows.map { r in
            (row: r, value: r.value(column).flatMap { $0.isFinite ? $0 : nil }, rank: rank?[r.name])
        }
        return keyed.sorted { a, b in
            switch (a.value, b.value) {
            case let (x?, y?) where x != y: return descending ? x > y : x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default:
                if a.row.name != b.row.name {
                    if let ra = a.rank, let rb = b.rank, ra != rb { return ra < rb }
                    let n = a.row.name.localizedStandardCompare(b.row.name)
                    if n != .orderedSame { return n == .orderedAscending }
                }
                return a.row.id.precedes(b.row.id)
            }
        }.map(\.row)
    }

    /// Owner rule for a group: at least one real member, every member readable and the current user's.
    nonisolated static func ownedByCurrentUser(_ members: [ProcessSample]) -> Bool {
        members.contains { !$0.id.isSynthetic }
            && !members.contains { !$0.isCurrentUser || $0.provenance != .measured }
    }

    /// Builds a row that isn't on screen this frame (collapsed child, app row in Processes mode).
    nonisolated static func row(for selection: NavigationModel.ProcessSelection, in out: ProcessTableOutput) -> ProcessRow? {
        switch selection {
        case .process(let id):
            guard let p = out.processByID[id] else { return nil }
            var row = processRow(p, responsibleID: out.responsible[p.app], health: out.health)
            row.depth = out.index[.app(p.app)] != nil ? 1 : 0
            return row
        case .app(let key):
            guard key != .other, let app = out.appByKey[key] else { return nil }
            let ms = out.membersByApp[key] ?? []
            let responsible = out.responsible[key].flatMap { out.processByID[$0] }
            var row = appRow(app, members: ms, responsible: responsible, health: out.health)
            let visibleCount = ms.reduce(0) { $0 + ($1.provenance != .restricted ? 1 : 0) }
            row.hasChildren = visibleCount > 1 || max(app.hiddenProcessCount, ms.count - visibleCount) > 0
            return row
        }
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
        let exited = p.id.isExitedResidual                                   // ICR-13 (`ProcessID.exitedResidual`)
        let rawKind = exited ? (p.name.isEmpty ? nil : exitedName) : processKind(p, responsibleID: responsibleID)
        // Never "Exited processes · Exited processes": a kind equal to the name is dropped.
        let kind = rawKind == p.name ? nil : rawKind
        // An app's main process shows its bundle ("/Applications/Final Cut Pro.app", DESIGN §3.12 inspector).
        let displayPath = kind == "App" ? p.path.map(trimmedBundle) : p.path
        var row = ProcessRow(
            id: .process(p.id), rowKind: .process, depth: 0, parity: 0,
            name: exited && p.name.isEmpty ? exitedName : p.name,
            kindLabel: kind,
            identity: AppIdentity(key: p.app, displayName: p.name, bundlePath: p.path.map(trimmedBundle)),
            pid: synthetic ? nil : p.pid, user: p.user, uid: p.uid, provenance: p.provenance,
            cpu: p.cpuPercent, gpu: p.gpuPercent, memory: p.memory,
            network: sum(p.netRxBps, p.netTxBps), disk: sum(p.diskReadBps, p.diskWriteBps), energy: p.energyWatts,
            reasons: processReasons(p, health: health),
            cpuEstimated: p.provenance == .coalition || exited, energyEstimated: p.energyEstimated || exited,
            hasChildren: false, isExpanded: false, processCount: 1, threads: p.threads, path: displayPath,
            appKey: p.app, ownedByCurrentUser: owned,
            foreignOwner: owned ? nil : (p.user ?? "uid \(p.uid)"), target: target)
        row.isExitedResidual = exited
        row.sampleID = synthetic ? nil : p.id
        if exited {
            // ICR-13 carries CPU, disk and energy only; the other cells are not tracked (not "Requires root").
            let na = "Not tracked for exited processes"
            row.reasons = ProcessCellReasons(cpu: row.reasons.cpu, gpu: row.gpu == nil ? na : nil,
                                             memory: row.memory == nil ? na : nil,
                                             network: row.network == nil ? na : nil,
                                             disk: row.reasons.disk, energy: row.reasons.energy)
        }
        return row
    }

    nonisolated static let exitedName = "Exited processes"

    /// Keeps each "Exited processes" row directly after the last row of its app (ICR-13), whatever the sort.
    nonisolated static func keepingExitedWithApp(_ rows: [ProcessRow]) -> [ProcessRow] {
        let exited = rows.filter(\.isExitedResidual)
        guard !exited.isEmpty else { return rows }
        var out = rows.filter { !$0.isExitedResidual }
        for e in exited {
            if let i = out.lastIndex(where: { $0.appKey == e.appKey && $0.rowKind != .restrictedSummary }) {
                out.insert(e, at: i + 1)
            } else {
                out.append(e)
            }
        }
        return out
    }

    private nonisolated static func appRow(_ app: AppSample, members: [ProcessSample], responsible: ProcessSample?,
                                           health: [SensorID: SensorStatus]) -> ProcessRow {
        let key = app.identity.key
        // Coalition groups (no readable member) are "System" rows (DESIGN §3.12 rule 3).
        let coalitionOnly = !members.isEmpty && members.allSatisfy { $0.provenance != .measured }
        let base = coalitionOnly ? "System" : baseKind(key: key, representative: responsible ?? members.first)
        // The ICR-13 "Exited processes" pseudo-row is not a process.
        let count = max(app.processIDs.filter { !$0.isExitedResidual }.count,
                        members.filter { !$0.id.isExitedResidual }.count)
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
            // Coalition groups have no known leader PID: "—" rather than an arbitrary member (ruling).
            pid: coalitionOnly ? nil : responsible?.pid, user: responsible?.user ?? members.first?.user,
            uid: responsible?.uid ?? members.first?.uid,
            provenance: members.allSatisfy { $0.provenance != .measured } && !members.isEmpty ? .coalition : .measured,
            cpu: app.cpuPercent, gpu: app.gpuPercent, memory: app.memory,
            network: sum(app.netRxBps, app.netTxBps), disk: sum(app.diskReadBps, app.diskWriteBps),
            energy: app.energyWatts, reasons: reasons,
            // Group values that include an ICR-13 exited share (`AppSample.exitedResidual`) are estimated too; the
            // "Estimated" tooltip never talks about hidden processes.
            cpuEstimated: members.contains { $0.provenance == .coalition } || app.exitedResidual != nil,
            energyEstimated: app.energyEstimated || app.exitedResidual != nil,
            hasChildren: false, isExpanded: false, processCount: count, threads: app.threads, path: path,
            appKey: key, ownedByCurrentUser: owned,
            foreignOwner: owned ? nil : (foreign?.user ?? responsible?.user ?? "another user"),
            target: real.isEmpty ? nil
                : .app(AppIdentity(key: key, displayName: app.identity.displayName, bundlePath: path),
                       pids: real.map(\.pid).sorted()),
            sampleID: coalitionOnly || responsible?.id.isSynthetic != false ? nil : responsible?.id)
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
