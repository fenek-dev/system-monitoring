import Foundation

// The only home of UnavailableSensor, FixtureSensor and CrashingSensor.

/// Always unavailable: `prepare()` and `sample()` throw `.unavailable(reason)`.
/// Used for the kill switch (`TELLTALE_DISABLE_SENSORS`) and `SensorSuite.allUnavailable`.
public final class UnavailableSensor<R: Sendable & Codable>: Sensor {
    public typealias Reading = R

    public let id: SensorID
    public let cadence: SensorCadence = .everyTick
    public let reason: String

    public init(_ id: SensorID, reason: String) {
        self.id = id
        self.reason = reason
    }

    public func prepare() throws(SensorError) {
        throw .unavailable(reason)
    }

    public func sample(_ ctx: SampleContext) throws(SensorError) -> (reading: R, capturedNs: UInt64) {
        throw .unavailable(reason)
    }

    public func invalidate() {}
}

/// Replays `readings` in order, one per `sample()`, then keeps returning the last one.
/// A `.failure` entry is thrown from `sample()`. `capturedNs` = `ctx.uptimeNs`.
/// No readings → `sample()` throws `.unavailable("no fixture readings")`.
public final class FixtureSensor<R: Sendable & Codable>: Sensor {
    public typealias Reading = R

    public let id: SensorID
    public let cadence: SensorCadence
    public let readings: [Result<R, SensorError>]
    /// Call counters for tests.
    public private(set) var prepareCount = 0, sampleCount = 0, invalidateCount = 0

    public init(_ id: SensorID, readings: [Result<R, SensorError>], cadence: SensorCadence = .everyTick) {
        self.id = id
        self.readings = readings
        self.cadence = cadence
    }

    public func prepare() throws(SensorError) {
        prepareCount += 1
    }

    public func sample(_ ctx: SampleContext) throws(SensorError) -> (reading: R, capturedNs: UInt64) {
        defer { sampleCount += 1 }
        guard !readings.isEmpty else { throw .unavailable("no fixture readings") }
        switch readings[min(sampleCount, readings.count - 1)] {
        case .success(let reading): return (reading, ctx.uptimeNs)
        case .failure(let error): throw error
        }
    }

    public func invalidate() {
        invalidateCount += 1
    }
}

/// Debug hook for the crash canary: forwards to `wrapped`, but calls abort() inside the first prepare().
public final class CrashingSensor<R: Sendable & Codable>: Sensor {
    public typealias Reading = R

    private let wrapped: any Sensor<R>
    private var crashed = false

    public init(wrapping: any Sensor<R>) {
        self.wrapped = wrapping
    }

    public var id: SensorID { wrapped.id }
    public var cadence: SensorCadence { wrapped.cadence }

    public func prepare() throws(SensorError) {
        if !crashed {
            crashed = true
            abort()
        }
        try wrapped.prepare()
    }

    public func sample(_ ctx: SampleContext) throws(SensorError) -> (reading: R, capturedNs: UInt64) {
        try wrapped.sample(ctx)
    }

    public func invalidate() {
        wrapped.invalidate()
    }
}
