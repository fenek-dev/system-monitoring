import CPrivate
import Foundation
import IOKit.hidsystem
import MonitorModel
import os

/// Raw HID temperature list (private IOHIDEventSystemClient, weak-linked). A full read costs 65–80 ms
/// (~1 ms IPC per service), so it runs on its own queue: `sample()` returns the last completed read and kicks
/// off the next; it waits (≤ 240 ms) only when there is no reading yet or the last one is stale.
/// Only with `.rawTemperatures` (Thermals page), 2 s, never in background (ARCHITECTURE §5.4).
public final class HIDTemperatureSensor: Sensor {
    public typealias Reading = TemperatureReading
    public let id: SensorID = .temperatures
    public let cadence: SensorCadence = .every(.seconds(2), background: nil, requires: .rawTemperatures)

    static let staleNs: UInt64 = 6_000_000_000
    static let maxWaitNs: UInt64 = 240_000_000

    private var box: HIDTemperatureBox?

    public init() {}

    public func prepare() throws(SensorError) {
        guard box == nil else { return }
        guard tt_hid_available() else { throw .unavailable("IOHIDEventSystemClient symbols missing") }
        box = HIDTemperatureBox(catalog: try? TemperatureCatalog.bundled())
    }

    public func sample(_ ctx: SampleContext) throws(SensorError) -> (reading: TemperatureReading, capturedNs: UInt64) {
        if box == nil { try prepare() }
        guard let box else { throw .unavailable("HID not prepared") }
        let now = w6bUptimeNs()
        let state = box.kick()
        if let last = state.last, now - last.capturedNs < Self.staleNs { return (last.reading, last.capturedNs) }
        // No (fresh) reading: wait for the read just kicked off.
        let deadline = now + Self.maxWaitNs
        while w6bUptimeNs() < deadline {
            usleep(5_000)
            let s = box.state
            if let last = s.last, last.capturedNs >= now { return (last.reading, last.capturedNs) }
            if !s.inFlight, let error = s.error { throw error }
        }
        if let last = box.state.last { return (last.reading, last.capturedNs) }
        throw .timeout
    }

    public func invalidate() { box = nil }
}

/// Sendable state shared with the HID queue. CF objects never leave the queue closure.
final class HIDTemperatureBox: Sendable {
    struct State: Sendable {
        var last: (reading: TemperatureReading, capturedNs: UInt64)?
        var inFlight = false
        var error: SensorError?
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "dev.telltale.hid-temps", qos: .utility)
    private let catalog: TemperatureCatalog?

    init(catalog: TemperatureCatalog?) { self.catalog = catalog }

    var state: State { lock.withLock { $0 } }

    /// Starts a read unless one is in flight; returns the state before the kick.
    @discardableResult
    func kick() -> State {
        let (before, start) = lock.withLock { s -> (State, Bool) in
            let b = s
            guard !s.inFlight else { return (b, false) }
            s.inFlight = true
            return (b, true)
        }
        if start {
            queue.async { [self] in
                let result = Self.readAll()
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
