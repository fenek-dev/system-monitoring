import Darwin
import Foundation
import MonitorDiskTools
import MonitorModel

/// `--scan <root>`: the storage scanner end to end (BulkLister → Scanner → ScanCache), nothing mocked.
extension Commands {
    static func scan(_ rootArgument: String, _ o: ProbeOptions) async {
        let home = NSHomeDirectory()
        let path = rootArgument == "~" ? home : (rootArgument as NSString).expandingTildeInPath
        let root: ScanRoot = path == home ? .home(home) : .folder(path)
        let trusted: TrustedRoot
        do {
            trusted = try TrustedRoot(path: path)
        } catch {
            print("scan: cannot open \(path): \(error)")
            exit(1)
        }
        let threads = o.scanThreads ?? MonitorDiskTools.Scanner.defaultThreadCount()
        let scanner = MonitorDiskTools.Scanner(lister: BulkLister(root: trusted), threads: threads, home: home)
        print("scan \(path) with \(threads) threads (FDA: \(FullDiskAccessProbe.check(home: home) ? "yes" : "no"))")

        let t0 = Clock.ns()
        var finished: StorageTree?
        var lastProgress = 0.0
        for await event in scanner.scan(root: root) {
            switch event {
            case let .progress(p):
                let now = Double(Clock.ns() - t0) / 1e9
                if !o.quiet, now - lastProgress >= 1 {
                    lastProgress = now
                    print(String(format: "  %5.1fs  %9d entries  %@", now, p.files, p.currentPath))
                }
            case let .finished(tree): finished = tree
            case let .failed(reason):
                print("scan failed: \(reason)")
                exit(1)
            case .partial, .classified: break
            }
        }
        let wall = Double(Clock.ns() - t0) / 1e9
        guard let tree = finished else {
            print("scan ended without a result")
            exit(1)
        }
        // Folded small files are entries too: nodes + folded counts = everything the walk saw.
        let entries = tree.nodeCount + tree.smallCount.reduce(0) { $0 + Int($1) }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        print(String(format: "entries %d  nodes %d  size %.1f GB  wall %.2f s  RSS %.0f MB  %.0f entries/s",
                     entries, tree.nodeCount, Double(tree.allocBytes[0]) / 1e9, wall,
                     Double(usage.ru_maxrss) / 1_048_576, Double(entries) / wall))

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("probe-scan-cache-\(UUID().uuidString)")
        defer {
            do {
                try FileManager.default.removeItem(at: dir)
            } catch {
                print("cleanup of \(dir.path) failed: \(error)")
            }
        }
        let cache = ScanCache(directory: dir)
        let tSave = Clock.ns()
        do {
            try cache.save(tree)
        } catch {
            print("cache save failed: \(error)")
            exit(1)
        }
        let tLoad = Clock.ns()
        let loaded = cache.load(root: tree.root, volumeUUID: tree.volumeUUID)
        let loadNs = Clock.ns() - tLoad
        print("cache: save \(Clock.ms(tLoad - tSave)) ms, load \(Clock.ms(loadNs)) ms, "
              + (loaded?.tree.nodeCount == tree.nodeCount ? "round-trip ok" : "ROUND-TRIP MISMATCH"))
    }
}
