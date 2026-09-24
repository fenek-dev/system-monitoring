import CPrivate
import Foundation
import IOKit.hidsystem
import MonitorModel
import os

/// Raw HID temperature list (private IOHIDEventSystemClient, weak-linked). A full read costs 65–80 ms
/// (~1 ms IPC per service), so it runs on its own queue and `sample()` NEVER waits for it: it kicks off the
/// next read and returns the last completed one (even if stale, e.g. when Thermals reopens — its `capturedNs`
/// tells the engine how old it is), or throws `.transient("warming up")` before the first read finished.
/// Only with `.rawTemperatures` (Thermals page), 2 s, never in background (ARCHITECTURE §5.4).
public final class HIDTemperatureSensor: Sensor {
    public typealias Reading = TemperatureReading
    public let id: SensorID = .temperatures
    public let cadence: SensorCadence = .every(.seconds(2), background: nil, requires: .rawTemperatures)

    private var box: HIDTemperatureBox?

    typealias Reader = @Sendable () -> Result<[HIDTemperatureParse.Sample], SensorError>
    private let reader: Reader

    public init() { reader = HIDTemperatureBox.readAll }
    /// Tests: inject the (slow) read to verify `sample()` never blocks on it.
    init(reader: @escaping Reader) { self.reader = reader }

    public func prepare() throws(SensorError) {
        guard box == nil else { return }
        guard tt_hid_available() else { throw .unavailable("IOHIDEventSystemClient symbols missing") }
        box = HIDTemperatureBox(catalog: try? TemperatureCatalog.bundled(), reader: reader)
    }

    public func sample(_ ctx: SampleContext) throws(SensorError) -> (reading: TemperatureReading, capturedNs: UInt64) {
        if box == nil { try prepare() }
        guard let box else { throw .unavailable("HID not prepared") }
        let state = box.kick()
        // S-M5: a read hung past its deadline → stale data is not served as fresh (slot → degraded).
        if state.stalled { throw .timeout }
        if let last = state.last { return (last.reading, last.capturedNs) }
        if let error = state.error { throw error }
        throw .transient("warming up")
    }

    public func invalidate() { box = nil }

    /// Tests / probes only: waits until a read newer than `after` completed (never used by `sample()`).
    /// Async (`Task.sleep`): a blocking poll would park a cooperative-pool thread.
    func waitForRead(after ns: UInt64, timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let last = box?.state.last, last.capturedNs > ns { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

/// Sendable state shared with the HID queue. CF objects never leave the queue closure.
final class HIDTemperatureBox: Sendable {
    struct State: Sendable {
        var last: (reading: TemperatureReading, capturedNs: UInt64)?
        var inFlight = false
        var error: SensorError?
        /// Uptime the in-flight read started.
        var startedNs: UInt64 = 0
        /// In the state `kick()` returns: the in-flight read has run past `readDeadlineNs`.
        var stalled = false
    }

    /// A full read takes 65–80 ms; one still running after this is hung (IOHIDServiceClientCopyEvent never returned).
    static let readDeadlineNs: UInt64 = 10_000_000_000

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "dev.telltale.hid-temps", qos: .utility)
    private let catalog: TemperatureCatalog?
    private let reader: HIDTemperatureSensor.Reader

    init(catalog: TemperatureCatalog?, reader: @escaping HIDTemperatureSensor.Reader = HIDTemperatureBox.readAll) {
        self.catalog = catalog
        self.reader = reader
    }

    var state: State { lock.withLock { $0 } }

    /// Starts a read unless one is in flight (a hung one is never doubled up); returns the state before the kick,
    /// with `stalled` set when the in-flight read is past its deadline.
    @discardableResult
    func kick(nowNs: UInt64 = w6bUptimeNs()) -> State {
        let (before, start) = lock.withLock { s -> (State, Bool) in
            var b = s
            guard !s.inFlight else {
                b.stalled = nowNs >= s.startedNs && nowNs - s.startedNs > Self.readDeadlineNs
                return (b, false)
            }
            s.inFlight = true
            s.startedNs = nowNs
            return (b, true)
        }
        if start {
            queue.async { [self] in
                let result = reader()
                let ns = w6bUptimeNs()
                lock.withLock { s in
                    s.inFlight = false
                    switch result {
                    case let .success(samples):
                        s.last = (HIDTemperatureParse.reading(samples, catalog: catalog), ns)
                        s.error = nil
                    case let .failure(e):
                        s.error = e
                    }
                }
            }
        }
        return before
    }

    /// One full read (client per read: no CF object outlives this call).
    static func readAll() -> Result<[HIDTemperatureParse.Sample], SensorError> {
        guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else {
            return .failure(.unavailable("IOHIDEventSystemClientCreate failed"))
        }
        let matching = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary
        _ = IOHIDEventSystemClientSetMatching(client, matching)
        guard let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient], !services.isEmpty else {
            return .failure(.unavailable("no HID temperature services"))
        }
        let type = Int64(kSMHIDEventTypeTemperature)
        let field = Int32(type << 16)
        var out: [HIDTemperatureParse.Sample] = []
        out.reserveCapacity(services.count)
        for svc in services {
            guard let name = IOHIDServiceClientCopyProperty(svc, "Product" as CFString) as? String,
                  let event = IOHIDServiceClientCopyEvent(svc, type, 0, 0) else { continue }   // dead service
            out.append(.init(name: name, celsius: IOHIDEventGetFloatValue(event, field)))
        }
        return out.isEmpty ? .failure(.transient("no HID temperature events")) : .success(out)
    }
}
