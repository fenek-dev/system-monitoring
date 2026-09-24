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

    @Test func appSeriesCapacity() {
        var h = LiveHistory(capacity: 300, appCapacity: 3, maxTrackedApps: 64)
        for t in 0..<10 { h.append(liveFrame(t: Double(t), apps: [liveApp("a", cpu: Double(t))])) }
        #expect(h.appSeries(AppKey(kind: .app, id: "a"), .cpu, window: .seconds(60)).map(\.value) == [7, 8, 9])
    }
}
