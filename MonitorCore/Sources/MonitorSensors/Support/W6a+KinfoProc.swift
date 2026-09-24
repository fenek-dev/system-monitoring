import Darwin
import MonitorModel

/// List fields of one `kinfo_proc` (sysctl KERN_PROC_ALL). Available for every pid, root included.
struct KinfoEntry: Sendable, Equatable, Codable {
    var pid: Int32
    var ppid: Int32
    var uid: UInt32
    var comm: String
    /// `p_starttime` in µs since the epoch; 0 if negative/unset.
    var startTimeUs: UInt64

    var id: ProcessID { ProcessID(pid: pid, startTimeUs: startTimeUs) }
}

/// Pure decoding of KERN_PROC_ALL output.
enum KinfoProcParser {
    static let maxComm = Int(MAXCOMLEN)   // 16

    static func entry(_ kp: kinfo_proc) -> KinfoEntry {
        let tv = kp.kp_proc.p_un.__p_starttime
        let start: UInt64 = (tv.tv_sec < 0 || tv.tv_usec < 0)
            ? 0
            : UInt64(tv.tv_sec) &* 1_000_000 &+ UInt64(tv.tv_usec)
        let comm = withUnsafeBytes(of: kp.kp_proc.p_comm) { raw -> String in
            let limit = min(raw.count, maxComm)
            var n = 0
            while n < limit && raw[n] != 0 { n += 1 }
            return String(decoding: UnsafeRawBufferPointer(rebasing: raw[0..<n]), as: UTF8.self)
        }
        return KinfoEntry(
            pid: kp.kp_proc.p_pid,
            ppid: kp.kp_eproc.e_ppid,
            uid: kp.kp_eproc.e_ucred.cr_uid,
            comm: comm,
            startTimeUs: start
        )
    }

    /// Decodes whole `kinfo_proc` records; a trailing partial record is ignored.
    static func entries(_ buffer: UnsafeRawBufferPointer) -> [KinfoEntry] {
        let stride = MemoryLayout<kinfo_proc>.stride
        let count = buffer.count / stride
        var out: [KinfoEntry] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let kp = buffer.loadUnaligned(fromByteOffset: i * stride, as: kinfo_proc.self)
            out.append(entry(kp))
        }
        return out
    }
}

/// Retained KERN_PROC_ALL buffer (~920 × 648 B); grows on ENOMEM, never shrinks.
final class KinfoProcList {
    private var buffer: UnsafeMutableRawBufferPointer
    private(set) var byteCount = 0

    init(initialCount: Int = 1024) {
        buffer = .allocate(byteCount: initialCount * MemoryLayout<kinfo_proc>.stride,
                           alignment: MemoryLayout<kinfo_proc>.alignment)
    }

    deinit { buffer.deallocate() }

    /// Fills the buffer and decodes it.
    func read() throws(SensorError) -> [KinfoEntry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        for _ in 0..<4 {
            var size = buffer.count
            if sysctl(&mib, 4, buffer.baseAddress, &size, nil, 0) == 0 {
                byteCount = size
                return KinfoProcParser.entries(UnsafeRawBufferPointer(rebasing: buffer[0..<size]))
            }
            let err = errno
            guard err == ENOMEM else { throw w6aErrnoError(err, "sysctl KERN_PROC_ALL") }
            var needed = 0
            guard sysctl(&mib, 4, nil, &needed, nil, 0) == 0 else {
                let e = errno
                throw w6aErrnoError(e, "sysctl KERN_PROC_ALL size")
            }
            let grown = max(needed + needed / 4, buffer.count * 2)
            buffer.deallocate()
            buffer = .allocate(byteCount: grown, alignment: MemoryLayout<kinfo_proc>.alignment)
        }
        throw SensorError.transient("sysctl KERN_PROC_ALL: process list kept growing")
    }
}
