import Foundation
import MonitorModel
@testable import MonitorEngine

let sec: UInt64 = 1_000_000_000
let testUID: UInt32 = 501

/// Own-uid, rusage-permitted process.
func own(_ pid: Int32, start: UInt64 = 1, cpuNs: UInt64 = 0, energyNJ: UInt64? = 0, footprint: UInt64? = 1_000,
         diskR: UInt64? = 0, diskW: UInt64? = 0, comm: String? = nil, path: String? = nil,
         responsible: Int32? = nil, threads: Int32? = 1) -> RawProcess {
    RawProcess(id: ProcessID(pid: pid, startTimeUs: start), ppid: 1, uid: testUID, comm: comm ?? "p\(pid)",
               name: comm ?? "p\(pid)", path: path, responsiblePID: responsible, cpuTimeNs: cpuNs,
               footprint: footprint, diskReadBytes: diskR, diskWriteBytes: diskW, energyNJ: energyNJ, threads: threads)
}

/// Foreign-uid process (rusage EPERM): list fields only.
func foreign(_ pid: Int32, start: UInt64 = 1, comm: String? = nil, uid: UInt32 = 0, path: String?? = .none) -> RawProcess {
    let c = comm ?? "r\(pid)"
    return RawProcess(id: ProcessID(pid: pid, startTimeUs: start), ppid: 1, uid: uid, comm: c,
                      path: path ?? "/usr/libexec/\(c)", restricted: true)
}

func table(_ ps: [RawProcess], at ns: UInt64) -> SensorResult<ProcessTableReading> {
    .fresh(ProcessTableReading(processes: ps), capturedNs: ns)
}

func appID(_ id: String, kind: AppKey.Kind = .app) -> AppIdentity {
    AppIdentity(key: AppKey(kind: kind, id: id), displayName: id)
}

extension Array where Element == ProcessSample {
    subscript(pid pid: Int32) -> ProcessSample? { first { $0.pid == pid } }
}
