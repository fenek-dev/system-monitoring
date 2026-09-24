import Foundation
import Darwin
import IOKit
import IOKit.pwr_mgt
import SystemConfiguration
import CoreWLAN
import CPrivate

// MARK: - Shared helpers

func measureMs<T>(_ body: () -> T) -> (T, Double) {
    let start = Date()
    let r = body()
    return (r, Date().timeIntervalSince(start) * 1000)
}

func ms(_ v: Double) -> String { String(format: "%.2f ms", v) }

func procName(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 256)
    return proc_name(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : "pid \(pid)"
}

// MARK: - 1. Disk IOPS/bytes (IOBlockStorageDriver Statistics)

struct DiskStats { var opsRead: UInt64 = 0; var opsWrite: UInt64 = 0; var bytesRead: UInt64 = 0; var bytesWrite: UInt64 = 0 }

func allBlockStorageDrivers() -> [io_service_t] {
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iter) == KERN_SUCCESS else { return [] }
    defer { IOObjectRelease(iter) }
    var result: [io_service_t] = []
    var svc = IOIteratorNext(iter)
    while svc != 0 { result.append(svc); svc = IOIteratorNext(iter) }
    return result
}

func bsdNameOfChild(_ driver: io_service_t) -> String? {
    var iter: io_iterator_t = 0
    guard IORegistryEntryGetChildIterator(driver, kIOServicePlane, &iter) == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(iter) }
    var found: String? = nil
    var child = IOIteratorNext(iter)
    while child != 0 {
        if found == nil, let cf = IORegistryEntryCreateCFProperty(child, "BSD Name" as CFString, kCFAllocatorDefault, 0) {
            found = cf.takeRetainedValue() as? String
        }
        IOObjectRelease(child)
        child = IOIteratorNext(iter)
    }
    return found
}

func diskStats(_ driver: io_service_t) -> DiskStats {
    guard let cf = IORegistryEntryCreateCFProperty(driver, "Statistics" as CFString, kCFAllocatorDefault, 0),
          let dict = cf.takeRetainedValue() as? [String: Any] else { return DiskStats() }
    func u64(_ k: String) -> UInt64 { (dict[k] as? NSNumber)?.uint64Value ?? 0 }
    return DiskStats(opsRead: u64("Operations (Read)"), opsWrite: u64("Operations (Write)"),
                      bytesRead: u64("Bytes (Read)"), bytesWrite: u64("Bytes (Write)"))
}

func runDiskIOPS() {
    print("== 1. Disk IOPS/bytes (IOBlockStorageDriver) ==")
    let drivers = allBlockStorageDrivers()
    defer { for d in drivers { IOObjectRelease(d) } }
    if drivers.isEmpty { print("  no IOBlockStorageDriver services found"); return }
    let names = drivers.map { bsdNameOfChild($0) ?? "?" }

    let (first, cost1) = measureMs { drivers.map { diskStats($0) } }
    Thread.sleep(forTimeInterval: 1.0)
    let (second, cost2) = measureMs { drivers.map { diskStats($0) } }

    print("  drivers=\(drivers.count) sample1=\(ms(cost1)) sample2=\(ms(cost2)) interval~1.0s")
    for i in 0..<drivers.count {
        let dr = Double(second[i].opsRead &- first[i].opsRead)
        let dw = Double(second[i].opsWrite &- first[i].opsWrite)
        let drb = Double(second[i].bytesRead &- first[i].bytesRead)
        let dwb = Double(second[i].bytesWrite &- first[i].bytesWrite)
        print("  [\(names[i])] readIOPS=\(String(format: "%.0f", dr)) writeIOPS=\(String(format: "%.0f", dw)) " +
              "readMBps=\(String(format: "%.3f", drb / 1_048_576)) writeMBps=\(String(format: "%.3f", dwb / 1_048_576))")
    }
}

// MARK: - 2. NVMe SMART (NVMeSMARTLib CFPlugIn via CPrivate C helper)

func findNVMeSMARTService() -> io_service_t {
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOServiceClass), &iter) == KERN_SUCCESS else { return 0 }
    defer { IOObjectRelease(iter) }
    var found: io_service_t = 0
    var svc = IOIteratorNext(iter)
    while svc != 0 {
        if found == 0,
           let cf = IORegistryEntryCreateCFProperty(svc, "NVMe SMART Capable" as CFString, kCFAllocatorDefault, 0),
           (cf.takeRetainedValue() as? Bool) == true {
            found = svc
        } else {
            IOObjectRelease(svc)
        }
        svc = IOIteratorNext(iter)
    }
    return found
}

func runNVMeSMART() {
    print("== 2. NVMe SMART (NVMeSMARTLibExternal.h) ==")
    let (svc, findCost) = measureMs { findNVMeSMARTService() }
    guard svc != 0 else {
        print("  not found: no IOService in the registry has 'NVMe SMART Capable'=true (findCost=\(ms(findCost)))")
        return
    }
    defer { IOObjectRelease(svc) }

    var nameBuf = [CChar](repeating: 0, count: 128)
    IORegistryEntryGetName(svc, &nameBuf)
    let svcName = String(cString: nameBuf)

    let (result, readCost) = measureMs { nvme_smart_read(svc) }
    print("  service=\(svcName) findCost=\(ms(findCost)) readCost=\(ms(readCost))")

    if result.success != 0 {
        let dataReadBytes = result.dataUnitsRead &* 512_000
        let dataWrittenBytes = result.dataUnitsWritten &* 512_000
        let celsius = Double(result.temperatureKelvin) - 273.15
        print("  percentageUsed=\(result.percentageUsed)%")
        print("  dataUnitsRead=\(result.dataUnitsRead) (\(String(format: "%.2f", Double(dataReadBytes) / 1e9)) GB)")
        print("  dataUnitsWritten=\(result.dataUnitsWritten) (\(String(format: "%.2f", Double(dataWrittenBytes) / 1e9)) GB)")
        print("  powerOnHours=\(result.powerOnHours) unsafeShutdowns=\(result.unsafeShutdowns)")
        print("  temperature=\(result.temperatureKelvin)K (\(String(format: "%.1f", celsius))C) " +
              "criticalWarning=0x\(String(format: "%02x", result.criticalWarning))")
    } else {
        let stageName = ["", "IOCreatePlugInInterfaceForService", "QueryInterface", "SMARTReadData"][min(max(Int(result.stage), 0), 3)]
        let errStr = String(cString: mach_error_string(mach_error_t(result.ioReturn)))
        print("  FAILED at stage \(result.stage) (\(stageName)) ioReturn=\(result.ioReturn) " +
              "(0x\(String(format: "%08x", UInt32(bitPattern: Int32(result.ioReturn))))) mach_error_string=\"\(errStr)\"")
    }
}

// MARK: - 3. Sleep assertions (IOPMCopyAssertionsByProcess)

func runSleepAssertions() {
    print("== 3. Sleep assertions (IOPMCopyAssertionsByProcess) ==")
    var dict: Unmanaged<CFDictionary>?
    let (kr, cost) = measureMs { () -> IOReturn in IOPMCopyAssertionsByProcess(&dict) }
    print("  cost=\(ms(cost)) kr=\(kr)")
    guard kr == kIOReturnSuccess, let cfDict = dict?.takeRetainedValue(), let byPid = cfDict as? [AnyHashable: Any] else {
        print("  IOPMCopyAssertionsByProcess failed or returned nothing (kr=\(kr))")
        return
    }

    var idleSystemCount = 0
    var idleDisplayCount = 0
    print("  processes with assertions: \(byPid.count)")
    for (key, value) in byPid {
        guard let pidNum = key as? NSNumber, let list = value as? [[String: Any]] else { continue }
        let pid = pidNum.int32Value
        var parts: [String] = []
        for a in list {
            let type = (a["AssertType"] as? String) ?? "?"
            let name = (a["AssertName"] as? String) ?? ""
            if type == "PreventUserIdleSystemSleep" { idleSystemCount += 1 }
            if type == "PreventUserIdleDisplaySleep" { idleDisplayCount += 1 }
            parts.append(name.isEmpty ? type : "\(type)(\"\(name)\")")
        }
        print("  pid=\(pid) name=\(procName(pid)) assertions=[\(parts.joined(separator: ", "))]")
    }
    print("  PreventUserIdleSystemSleep=\(idleSystemCount) PreventUserIdleDisplaySleep=\(idleDisplayCount)")
}

// MARK: - 4. Router latency and loss

func gatewayViaSysctl() -> String? {
    var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_GATEWAY]
    var len = 0
    guard sysctl(&mib, u_int(mib.count), nil, &len, nil, 0) == 0, len > 0 else { return nil }
    var buf = [UInt8](repeating: 0, count: len)
    guard sysctl(&mib, u_int(mib.count), &buf, &len, nil, 0) == 0 else { return nil }

    func ipString(_ raw: UnsafeRawBufferPointer, at offset: Int, saLen: Int, limit: Int) -> String? {
        let want = MemoryLayout<sockaddr_in>.size
        var bytes = [UInt8](repeating: 0, count: want)
        let copyLen = max(0, min(saLen, want, limit - offset))
        if copyLen > 0 {
            for j in 0..<copyLen { bytes[j] = raw.load(fromByteOffset: offset + j, as: UInt8.self) }
        }
        let sin = bytes.withUnsafeBytes { $0.load(as: sockaddr_in.self) }
        var addr = sin.sin_addr
        var ipbuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &addr, &ipbuf, socklen_t(ipbuf.count)) != nil else { return nil }
        return String(cString: ipbuf)
    }

    return buf.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> String? in
        var offset = 0
        while offset + MemoryLayout<rt_msghdr>.size <= len {
            let rtm = raw.load(fromByteOffset: offset, as: rt_msghdr.self)
            let msglen = Int(rtm.rtm_msglen)
            if msglen <= 0 { break }
            let msgEnd = offset + msglen
            var addrOffset = offset + MemoryLayout<rt_msghdr>.size
            var dstIsDefault = false
            var gateway: String? = nil

            for i in 0..<Int32(RTAX_MAX) {
                let bit = Int32(1) << i
                guard (rtm.rtm_addrs & bit) != 0, addrOffset < msgEnd else { continue }
                let sa = raw.load(fromByteOffset: addrOffset, as: sockaddr.self)
                let saLen = Int(sa.sa_len) == 0 ? MemoryLayout<sockaddr>.size : Int(sa.sa_len)
                if sa.sa_family == sa_family_t(AF_INET) {
                    let ip = ipString(raw, at: addrOffset, saLen: saLen, limit: msgEnd)
                    if i == Int32(RTAX_DST), ip == "0.0.0.0" { dstIsDefault = true }
                    if i == Int32(RTAX_GATEWAY) { gateway = ip }
                }
                let rounded = saLen <= 0 ? MemoryLayout<Int>.size
                    : ((saLen + MemoryLayout<Int>.size - 1) / MemoryLayout<Int>.size) * MemoryLayout<Int>.size
                addrOffset += rounded
            }
            if dstIsDefault, let gw = gateway { return gw }
            offset += msglen
        }
        return nil
    }
}

func gatewayViaSCDynamicStore() -> String? {
    guard let store = SCDynamicStoreCreate(nil, "spike-extras" as CFString, nil, nil) else { return nil }
    guard let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) else { return nil }
    guard let dict = value as? [String: Any] else { return nil }
    return dict["Router"] as? String
}

func gatewayViaRouteCommand() -> String? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/sbin/route")
    task.arguments = ["-n", "get", "default"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    do { try task.run() } catch { return nil }
    task.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let out = String(data: data, encoding: .utf8) else { return nil }
    for line in out.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("gateway:") {
            return trimmed.replacingOccurrences(of: "gateway:", with: "").trimmingCharacters(in: .whitespaces)
        }
    }
    return nil
}

func icmpChecksum(_ data: [UInt8]) -> UInt16 {
    var sum: UInt32 = 0
    var i = 0
    while i + 1 < data.count {
        sum += (UInt32(data[i]) << 8) | UInt32(data[i + 1])
        i += 2
    }
    if i < data.count { sum += UInt32(data[i]) << 8 }
    while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
    return ~UInt16(sum & 0xffff)
}

func pingOnce(fd: Int32, dest: sockaddr_in, identifier: UInt16, seq: UInt16, timeout: TimeInterval) -> Double? {
    var packet = [UInt8](repeating: 0, count: 16)
    packet[0] = 8 // ICMP_ECHO
    packet[1] = 0 // code
    packet[2] = 0; packet[3] = 0 // checksum, filled below
    packet[4] = UInt8(identifier >> 8); packet[5] = UInt8(identifier & 0xff)
    packet[6] = UInt8(seq >> 8); packet[7] = UInt8(seq & 0xff)
    for i in 8..<packet.count { packet[i] = UInt8(i) } // arbitrary payload

    let cksum = icmpChecksum(packet)
    packet[2] = UInt8(cksum >> 8); packet[3] = UInt8(cksum & 0xff)

    var destAddr = dest
    let start = Date()
    let sent = withUnsafePointer(to: &destAddr) { destPtr -> Int in
        destPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            packet.withUnsafeBytes { buf in
                sendto(fd, buf.baseAddress, buf.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
    guard sent > 0 else { return nil }

    let deadline = start.addingTimeInterval(timeout)
    while true {
        let remaining = deadline.timeIntervalSinceNow
        if remaining <= 0 { return nil }
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let rc = poll(&pfd, 1, Int32(remaining * 1000))
        if rc <= 0 { return nil }

        var recvBuf = [UInt8](repeating: 0, count: 1024)
        let n = recvBuf.withUnsafeMutableBytes { rb -> Int in
            recvfrom(fd, rb.baseAddress, rb.count, 0, nil, nil)
        }
        // Gotcha: even on SOCK_DGRAM/IPPROTO_ICMP (unprivileged "ping" sockets),
        // macOS delivers the reply with the IPv4 header still attached (like a raw
        // socket), unlike UDP where the kernel strips it. Skip the IHL*4 bytes
        // before reading the ICMP header, or every field read is just IP-header
        // garbage (confirmed by instrumentation: recvBuf[0]==0x45 == IPv4 "version
        // 4, IHL 5", not ICMP type 0).
        guard n >= 20 else { continue }
        let ihl = Int(recvBuf[0] & 0x0f) * 4
        guard n >= ihl + 8 else { continue }
        let replyType = recvBuf[ihl]
        let replyId = (UInt16(recvBuf[ihl + 4]) << 8) | UInt16(recvBuf[ihl + 5])
        let replySeq = (UInt16(recvBuf[ihl + 6]) << 8) | UInt16(recvBuf[ihl + 7])
        if replyType == 0, replyId == identifier, replySeq == seq { // ICMP_ECHOREPLY
            return Date().timeIntervalSince(start) * 1000
        }
    }
}

func runRouterPing() {
    print("== 4. Router latency and loss ==")
    let (sysctlGw, sysctlCost) = measureMs { gatewayViaSysctl() }
    let (scGw, scCost) = measureMs { gatewayViaSCDynamicStore() }
    print("  sysctl(NET_RT_FLAGS,RTF_GATEWAY)=\(sysctlGw ?? "nil") cost=\(ms(sysctlCost))")
    print("  SCDynamicStore State:/Network/Global/IPv4/Router=\(scGw ?? "nil") cost=\(ms(scCost))")

    var gateway = sysctlGw ?? scGw
    var source = sysctlGw != nil ? "sysctl" : (scGw != nil ? "SCDynamicStore" : "none")
    if gateway == nil {
        let (routeGw, routeCost) = measureMs { gatewayViaRouteCommand() }
        print("  fallback `route -n get default`=\(routeGw ?? "nil") cost=\(ms(routeCost))")
        gateway = routeGw
        source = routeGw != nil ? "route(fallback)" : "none"
    }

    guard let gw = gateway else {
        print("  could not determine default gateway by any method")
        return
    }
    print("  using gateway=\(gw) (source=\(source))")

    let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
    guard fd >= 0 else {
        print("  socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP) failed: errno=\(errno) (\(String(cString: strerror(errno))))")
        return
    }
    defer { close(fd) }

    var dest = sockaddr_in()
    dest.sin_family = sa_family_t(AF_INET)
    dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    guard inet_pton(AF_INET, gw, &dest.sin_addr) == 1 else {
        print("  inet_pton failed for \(gw)")
        return
    }

    let identifier = UInt16(getpid() & 0xffff)
    var rtts: [Double] = []
    var sent = 0
    let (_, totalCost) = measureMs {
        for seq in 0..<5 {
            sent += 1
            if let rtt = pingOnce(fd: fd, dest: dest, identifier: identifier, seq: UInt16(seq), timeout: 1.0) {
                rtts.append(rtt)
            }
            if seq < 4 { Thread.sleep(forTimeInterval: 0.2) }
        }
    }

    let lossPct = 100.0 * Double(sent - rtts.count) / Double(sent)
    print("  sent=\(sent) received=\(rtts.count) loss=\(String(format: "%.0f", lossPct))% totalCost=\(ms(totalCost))")
    if !rtts.isEmpty {
        let minRtt = rtts.min()!, maxRtt = rtts.max()!, avgRtt = rtts.reduce(0, +) / Double(rtts.count)
        print("  rtt min/avg/max = \(String(format: "%.2f", minRtt))/\(String(format: "%.2f", avgRtt))/\(String(format: "%.2f", maxRtt)) ms")
    }
}

// MARK: - 5. Wi-Fi (CoreWLAN)

func channelWidthName(_ w: CWChannelWidth) -> String {
    switch w.rawValue {
    case 0: return "unknown"
    case 1: return "20MHz"
    case 2: return "40MHz"
    case 3: return "80MHz"
    case 4: return "160MHz"
    default: return "?(\(w.rawValue))"
    }
}

func channelBandName(_ b: CWChannelBand) -> String {
    switch b.rawValue {
    case 0: return "unknown"
    case 1: return "2GHz"
    case 2: return "5GHz"
    case 3: return "6GHz"
    default: return "?(\(b.rawValue))"
    }
}

func runWiFi() {
    print("== 5. Wi-Fi (CoreWLAN) ==")
    let (iface, cost) = measureMs { CWWiFiClient.shared().interface() }
    print("  cost=\(ms(cost))")
    guard let iface = iface else {
        print("  CWWiFiClient.shared().interface() returned nil (no Wi-Fi hardware, or Wi-Fi is off)")
        return
    }
    let rssi = iface.rssiValue()
    let noise = iface.noiseMeasurement()
    let rate = iface.transmitRate()
    let ssid = iface.ssid()
    print("  interfaceName=\(iface.interfaceName ?? "?")")
    print("  rssi=\(rssi) dBm noise=\(noise) dBm transmitRate=\(rate) Mbps")
    print("  ssid=\(ssid.map { "\"\($0)\"" } ?? "nil (expected without Location permission)")")
    if let channel = iface.wlanChannel() {
        print("  channel=\(channel.channelNumber) band=\(channelBandName(channel.channelBand)) width=\(channelWidthName(channel.channelWidth))")
    } else {
        print("  wlanChannel=nil")
    }
}

// MARK: - main

runDiskIOPS()
runNVMeSMART()
runSleepAssertions()
runRouterPing()
runWiFi()
