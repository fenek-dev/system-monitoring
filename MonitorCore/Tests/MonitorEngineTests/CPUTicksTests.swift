import MonitorModel
import Testing
@testable import MonitorEngine

@Suite struct CPUTicksTests {
    @Test func perCoreAndTotals() throws {
        let prev = [CoreTicks(user: 100, system: 100, idle: 100, nice: 0), CoreTicks(user: 0, system: 0, idle: 0, nice: 0)]
        let cur = [CoreTicks(user: 150, system: 110, idle: 140, nice: 0),      // busy 60 / 100
                   CoreTicks(user: 10, system: 0, idle: 90, nice: 0)]          // busy 10 / 100
        let u = try #require(CPUTicks.usage(previous: prev, current: cur))
        #expect(u.perCore == [0.6, 0.1])
        #expect(u.user == 0.3)
        #expect(u.system == 0.05)
        #expect(u.idle == 0.65)
        #expect(abs(u.user + u.system + u.idle - 1) < 1e-12)
    }

    @Test func niceCountsAsUser() throws {
        let u = try #require(CPUTicks.usage(previous: [CoreTicks()], current: [CoreTicks(user: 10, idle: 80, nice: 10)]))
        #expect(u.user == 0.2)
        #expect(u.perCore == [0.2])
    }

    @Test func idleCoreWithoutTicksIsZero() throws {
        let t = [CoreTicks(user: 5, system: 5, idle: 5)]
        let u = try #require(CPUTicks.usage(previous: t, current: t))
        #expect(u.perCore == [0])
        #expect(u.user == 0 && u.system == 0 && u.idle == 0)
    }

    @Test func mismatchedOrEmptyIsNil() {
        #expect(CPUTicks.usage(previous: [], current: []) == nil)
        #expect(CPUTicks.usage(previous: [CoreTicks()], current: [CoreTicks(), CoreTicks()]) == nil)
    }

    @Test func hugeDeltasDoNotTrap() throws {
        let big = UInt64.max / 2
        let u = try #require(CPUTicks.usage(previous: [CoreTicks(), CoreTicks()],
                                             current: [CoreTicks(user: big, system: big, idle: big, nice: big),
                                                       CoreTicks(user: big, system: big, idle: big, nice: big)]))
        #expect(abs(u.perCore[0] - 0.75) < 1e-9)
        #expect(abs(u.idle - 0.25) < 1e-9)
    }

    @Test func counterDecreaseIsNil() {
        let prev = [CoreTicks(user: 100, system: 100, idle: 100)]
        #expect(CPUTicks.usage(previous: prev, current: [CoreTicks(user: 1, system: 200, idle: 200)]) == nil)
    }
}
