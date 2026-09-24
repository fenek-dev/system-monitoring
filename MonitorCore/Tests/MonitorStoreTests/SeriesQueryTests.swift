import Foundation
import MonitorModel
import Testing
@testable import MonitorStore

@Suite struct SeriesQueryTests {
    private func hourStore(skip: ClosedRange<TimeInterval>? = nil) async throws -> HistoryStore {
        let store = try HistoryStore(location: .inMemory, config: T.config(TestClock()))
        try await T.fill(store, from: T.t0, duration: 3_600) { t, i in
            if let skip, skip.contains(t.timeIntervalSince(T.t0)) {
                return T.record(at: t, system: [:])   // replaced below by a filter
            }
            return T.record(at: t, system: [.cpuUsage: Double(i % 3) * 10, .memUsed: 100])
        }
        if let skip {
            let from = (T.t0 + skip.lowerBound).unixMs, to = (T.t0 + skip.upperBound).unixMs
            try await store.execute("DELETE FROM system_raw WHERE ts BETWEEN \(from) AND \(to)")
        }
        return store
    }

    @Test func defaultBucketIsRangeDisplayBucketAndAverages() async throws {
        let store = try await hourStore()
        let result = try await store.series([.cpuUsage], range: .hour, end: T.t0 + 3_600)
        let points = try #require(result[.cpuUsage])
        #expect(points.count == 240)                                   // 1 h / 15 s
        #expect(points.first?.time == T.t0)
        #expect(points[1].time == T.t0 + 15)
        #expect(points.last?.time == T.t0 + 3_585)
        // Each 15 s bucket holds samples i%3 = 0,1,2 → (0 + 10 + 20) / 3.
        #expect(points.allSatisfy { $0.value.map { abs($0 - 10) < 1e-9 } ?? false })
    }

    @Test func explicitBucketOverridesDefault() async throws {
        let store = try await hourStore()
        let result = try await store.series([.cpuUsage, .memUsed], range: .hour, end: T.t0 + 3_600, bucket: .seconds(60))
        #expect(result[.cpuUsage]?.count == 60)
        #expect(result[.memUsed]?.allSatisfy { $0.value == 100 } == true)
    }

    @Test func emptyBucketsAreGapPoints() async throws {
        let store = try await hourStore(skip: 1_200...1_799)   // paused 20:00–29:59
        let points = try #require(try await store.series([.memUsed], range: .hour, end: T.t0 + 3_600)[.memUsed])
        #expect(points.count == 240)
        let gap = points.filter { $0.time >= T.t0 + 1_200 && $0.time < T.t0 + 1_800 }
        #expect(gap.count == 40)
        #expect(gap.allSatisfy { $0.value == nil })
        #expect(points.filter { $0.value == nil }.count == 40)
    }

    @Test func missingMetricValuesAreNil() async throws {
        let store = try await hourStore()
        let points = try #require(try await store.series([.gpuUsage], range: .hour, end: T.t0 + 3_600)[.gpuUsage])
        #expect(points.count == 240)
        #expect(points.allSatisfy { $0.value == nil })
    }

    @Test func nanIsStoredAndReturnedAsNil() async throws {
        let store = try HistoryStore(location: .inMemory, config: T.config(TestClock()))
        try await T.fill(store, from: T.t0, duration: 60) { t, _ in T.record(at: t, system: [.cpuUsage: .nan]) }
        let points = try #require(try await store.series([.cpuUsage], range: .hour, end: T.t0 + 3_600)[.cpuUsage])
        #expect(points.allSatisfy { $0.value == nil })
    }

    @Test func windowExcludesRowsOutsideRange() async throws {
        let store = try HistoryStore(location: .inMemory, config: T.config(TestClock()))
        for (offset, value) in [(-5.0, 1_000.0), (0, 1), (3_595, 3), (3_600, 1_000)] {
            await store.append(RecordBatch(record: T.record(at: T.t0 + offset, system: [.cpuUsage: value])))
        }
        try await store.flush()
        let points = try #require(try await store.series([.cpuUsage], range: .hour, end: T.t0 + 3_600)[.cpuUsage])
        #expect(points.count == 240)
        #expect(points.first?.value == 1)
        #expect(points.last?.value == 3)
        #expect(points.compactMap(\.value).count == 2)
    }

    @Test func unalignedEndKeepsEpochAlignedBuckets() async throws {
        let store = try await hourStore()
        let points = try #require(try await store.series([.memUsed], range: .hour, end: T.t0 + 3_607)[.memUsed])
        #expect(points.first?.time == T.t0)            // floor(start / 15 s)
        #expect(points.last?.time == T.t0 + 3_600)
        #expect(points.count == 241)
    }
}
