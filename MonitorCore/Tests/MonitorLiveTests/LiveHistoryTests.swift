import Foundation
import Testing
import MonitorModel
@testable import MonitorLive

func liveFrame(
    t: Double, cpu: Double? = 0.5, mode: SamplingMode = .interactive, interval: Duration? = .seconds(1),
    apps: [AppSample] = []
) -> SystemFrame {
    var m = SystemMetrics()
    m[.cpuUsage] = cpu
    return SystemFrame(wallTime: Date(timeIntervalSince1970: t), uptimeNs: UInt64(t * 1e9), interval: interval,
                       mode: mode, apps: apps, metrics: m)
}

func liveApp(_ id: String, cpu: Double?, kind: AppKey.Kind = .app, watts: Double? = nil) -> AppSample {
    AppSample(identity: AppIdentity(key: AppKey(kind: kind, id: id), displayName: id), cpuPercent: cpu, energyWatts: watts)
}

@Suite struct LiveHistoryTests {
    @Test func seriesReturnsPointsInsideWindow() {
        var h = LiveHistory(capacity: 300)
        for t in 0..<100 { h.append(liveFrame(t: Double(t), cpu: Double(t) / 100)) }
        let s = h.series(.cpuUsage, window: .seconds(10))
        #expect(s.count == 11)                       // t = 89…99 inclusive
        #expect(s.first?.time == Date(timeIntervalSince1970: 89))
        #expect(s.last?.value == 0.99)
    }

    @Test func capacityBoundsHistory() {
        var h = LiveHistory(capacity: 5)
        for t in 0..<20 { h.append(liveFrame(t: Double(t))) }
        #expect(h.series(.cpuUsage, window: .seconds(3_600)).count == 5)
    }

    @Test func missingMetricIsGapPoint() {
        var h = LiveHistory()
        h.append(liveFrame(t: 0, cpu: nil))
        #expect(h.series(.cpuUsage, window: .seconds(60)) == [SeriesPoint(time: Date(timeIntervalSince1970: 0), value: nil)])
    }

    @Test func timeJumpInsertsGapPoint() {
        var h = LiveHistory()
        h.append(liveFrame(t: 0))
        h.append(liveFrame(t: 1))
        h.append(liveFrame(t: 30))                   // 29 s jump at 1 s cadence
        let s = h.series(.cpuUsage, window: .seconds(60))
        #expect(s.count == 4)
        #expect(s[2].value == nil)
        #expect(s[2].time > s[1].time && s[2].time < s[3].time)
    }

    @Test func backgroundCadenceIsNotAGap() {
        var h = LiveHistory()
        h.append(liveFrame(t: 0, mode: .background, interval: .seconds(5)))
        h.append(liveFrame(t: 5, mode: .background, interval: .seconds(5)))
        h.append(liveFrame(t: 6, mode: .interactive))    // switching to interactive: no gap either
        #expect(h.series(.cpuUsage, window: .seconds(60)).allSatisfy { $0.value != nil })
    }

    @Test func explicitGapAndNoDoubleGap() {
        var h = LiveHistory()
        h.append(liveFrame(t: 0))
        h.appendGap(at: Date(timeIntervalSince1970: 1))
        h.appendGap(at: Date(timeIntervalSince1970: 2))
        h.append(liveFrame(t: 3))
        let s = h.series(.cpuUsage, window: .seconds(60))
        #expect(s.map { $0.value == nil } == [false, true, false])
    }

    @Test func sameTimeFrameIsIgnored() {
        var h = LiveHistory()
        h.append(liveFrame(t: 0, cpu: 0.1))
        #expect(h.append(liveFrame(t: 0, cpu: 0.9)) == false)
        #expect(h.series(.cpuUsage, window: .seconds(60)).map(\.value) == [0.1])
    }

    @Test func clockGoingBackwardsRestarts() {
        var h = LiveHistory()
        h.append(liveFrame(t: 10))
        h.append(liveFrame(t: 11))
        h.append(liveFrame(t: 5))
        #expect(h.series(.cpuUsage, window: .seconds(60)).map(\.time) == [Date(timeIntervalSince1970: 5)])
    }

    @Test func appSeriesTracksTopAppsOnly() {
        var h = LiveHistory(capacity: 300, appCapacity: 120, maxTrackedApps: 2)
        let apps = [liveApp("a", cpu: 30), liveApp("b", cpu: 20), liveApp("c", cpu: 10)]
        h.append(liveFrame(t: 0, apps: apps))
        h.append(liveFrame(t: 1, apps: apps))
        let a = AppKey(kind: .app, id: "a"), c = AppKey(kind: .app, id: "c")
        #expect(h.appSeries(a, .cpu, window: .seconds(60)).map(\.value) == [30, 30])
        #expect(h.appSeries(c, .cpu, window: .seconds(60)).isEmpty)
        #expect(h.trackedAppCount == 2)
    }

    @Test func appLeavingTopIsEvictedAndAbsentAppGetsGap() {
        var h = LiveHistory(capacity: 300, appCapacity: 120, maxTrackedApps: 2)
        h.append(liveFrame(t: 0, apps: [liveApp("a", cpu: 30), liveApp("b", cpu: 20)]))
        h.append(liveFrame(t: 1, apps: [liveApp("a", cpu: 30)]))                         // b absent → gap
        let b = AppKey(kind: .app, id: "b")
        #expect(h.appSeries(b, .cpu, window: .seconds(60)).map(\.value) == [20, nil])
        h.append(liveFrame(t: 2, apps: [liveApp("a", cpu: 30), liveApp("c", cpu: 25)]))  // c enters, b evicted
        #expect(h.trackedAppCount == 2)
        #expect(h.appSeries(b, .cpu, window: .seconds(60)).isEmpty)
        #expect(h.appSeries(AppKey(kind: .app, id: "c"), .cpu, window: .seconds(60)).map(\.value) == [25])
    }

    @Test func appendDoesNotReallocateBuffers() {
        var h = LiveHistory(capacity: 10, appCapacity: 10, maxTrackedApps: 64)
        let apps = (0..<64).map { liveApp("app\($0)", cpu: Double(100 - $0)) }
        h.append(liveFrame(t: 0, apps: apps))
        let before = h.appStorageAddresses()
        let systemBefore = h.systemStorageAddress
        #expect(before.count == 64)
        for t in 1...30 { h.append(liveFrame(t: Double(t), apps: apps)) }   // also wraps the rings
        h.appendGap(at: Date(timeIntervalSince1970: 31))
        #expect(h.appStorageAddresses() == before)
        #expect(h.systemStorageAddress == systemBefore)
    }

    @Test func churnOfManyAppsStaysBounded() {
        var h = LiveHistory(capacity: 300, appCapacity: 120, maxTrackedApps: 64)
        let anchor = AppKey(kind: .app, id: "anchor")
        for t in 0..<200 {
            // anchor always first; 70 others rotate through a pool of 500 keys
            var apps = [liveApp("anchor", cpu: 1_000)]
            apps += (0..<70).map { liveApp("p\((t * 70 + $0) % 500)", cpu: Double(70 - $0)) }
            h.append(liveFrame(t: Double(t), apps: apps))
            #expect(h.trackedAppCount <= 64)
        }
        let s = h.appSeries(anchor, .cpu, window: .seconds(3_600))
        #expect(s.count == 120)
        #expect(s.allSatisfy { $0.value == 1_000 })
    }

    @Test func pauseGapReachesAppSeries() {
        var h = LiveHistory()
        let apps = [liveApp("a", cpu: 5)]
        h.append(liveFrame(t: 0, apps: apps))
        h.appendGap(at: Date(timeIntervalSince1970: 1))
        h.append(liveFrame(t: 60, apps: apps))
        #expect(h.appSeries(AppKey(kind: .app, id: "a"), .cpu, window: .seconds(120)).map(\.value) == [5, nil, 5])
    }

    @Test func usesEngineMetricsVector() {
        var h = LiveHistory()
        var a = liveApp("a", cpu: 5)
        a.metrics[.cpu] = 5
        a.metrics[.energy] = 2
        h.append(liveFrame(t: 0, apps: [a]))
        #expect(h.appSeries(AppKey(kind: .app, id: "a"), .energy, window: .seconds(60)).map(\.value) == [2])
    }

    // MARK: 1-s chart grid (U-I1)

    /// 12 background points 5 s apart, then 10 interactive points 1 s apart (the popover opened at t = 56):
    /// every sample sits in the slot of its own time; the slots between background points are gaps.
    @Test func gridPlacesMixedCadencePointsByTime() {
        var h = LiveHistory()
        for k in 0..<12 {
            let t = Double(k * 5)
            h.append(liveFrame(t: t, cpu: t, mode: .background, interval: .seconds(5)))
        }
        for t in 56...65 { h.append(liveFrame(t: Double(t), cpu: Double(t))) }
        let s = h.gridSeries(.cpuUsage, window: .seconds(60))
        #expect(s.count == 61)
        // Slot k is at t = 5 + k (newest 65 − 60 s); x = k / 60 of the chart width.
        for (k, p) in s.enumerated() {
            let t = 5 + Double(k)
            #expect(p.time == Date(timeIntervalSince1970: t))
            let expected: Double? = (t <= 55 ? t.truncatingRemainder(dividingBy: 5) == 0 : true) ? t : nil
            #expect(p.value == expected, "slot \(k)")
        }
        // The 55 s of background history take 50/60 of the width, the last 10 s the rest (not 57 % / 43 %).
        #expect(s.firstIndex { $0.value == 56 } == 51)
    }

    @Test func gridShortHistoryFillsOnlyTheRightEnd() {
        var h = LiveHistory()
        for t in 0..<10 { h.append(liveFrame(t: Double(t))) }
        let s = h.gridSeries(.cpuUsage, window: .seconds(60))
        #expect(s.count == 61)
        #expect(s.prefix(51).allSatisfy { $0.value == nil })
        #expect(s.suffix(10).allSatisfy { $0.value == 0.5 })
    }

    @Test func gridJitterNeverOpensAGap() {
        var h = LiveHistory()
        for k in 0..<80 { h.append(liveFrame(t: Double(k) * 1.04 + (k.isMultiple(of: 3) ? 0.06 : 0))) }
        let s = h.gridSeries(.cpuUsage, window: .seconds(60))
        #expect(s.count == 61)
        #expect(s.allSatisfy { $0.value != nil })
    }

    @Test func gridKeepsPauseGap() {
        var h = LiveHistory()
        h.append(liveFrame(t: 0))
        h.append(liveFrame(t: 1))
        h.append(liveFrame(t: 30))                   // 29 s jump → gap entry between
        let s = h.gridSeries(.cpuUsage, window: .seconds(60))
        #expect(s.count == 61)
        #expect(s.compactMap(\.value).count == 3)
        #expect(s[60].value != nil && s[31].value != nil && s[30].value != nil)
        #expect(s[32..<60].allSatisfy { $0.value == nil })
    }

    @Test func gridAppSeriesMatchesSystemGrid() {
        var h = LiveHistory()
        for k in 0..<3 {
            h.append(liveFrame(t: Double(k * 5), mode: .background, interval: .seconds(5), apps: [liveApp("a", cpu: 1)]))
        }
        let s = h.gridAppSeries(AppKey(kind: .app, id: "a"), .cpu, window: .seconds(10))
        #expect(s.map(\.value) == [1, nil, nil, nil, nil, 1, nil, nil, nil, nil, 1])
        #expect(h.gridAppSeries(AppKey(kind: .app, id: "zz"), .cpu, window: .seconds(10)).isEmpty)
    }

    @Test func appSeriesCapacity() {
        var h = LiveHistory(capacity: 300, appCapacity: 3, maxTrackedApps: 64)
        for t in 0..<10 { h.append(liveFrame(t: Double(t), apps: [liveApp("a", cpu: Double(t))])) }
        #expect(h.appSeries(AppKey(kind: .app, id: "a"), .cpu, window: .seconds(60)).map(\.value) == [7, 8, 9])
    }
}
