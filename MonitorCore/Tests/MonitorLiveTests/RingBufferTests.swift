import Testing
@testable import MonitorLive

@Suite struct RingBufferTests {
    @Test func emptyBuffer() {
        let b = RingBuffer<Int>(capacity: 3)
        #expect(b.isEmpty)
        #expect(b.count == 0)
        #expect(b.capacity == 3)
        #expect(Array(b) == [])
    }

    @Test func appendBelowCapacityKeepsOrder() {
        var b = RingBuffer<Int>(capacity: 3)
        b.append(1)
        b.append(2)
        #expect(Array(b) == [1, 2])
        #expect(b.first == 1)
        #expect(b.last == 2)
    }

    @Test func overwritesOldestWhenFull() {
        var b = RingBuffer<Int>(capacity: 3)
        for i in 1...7 { b.append(i) }
        #expect(b.count == 3)
        #expect(Array(b) == [5, 6, 7])
        #expect(b[0] == 5)
        #expect(b[2] == 7)
        #expect(Array(b.reversed()) == [7, 6, 5])
    }

    @Test func zeroCapacityIsClampedToOne() {
        var b = RingBuffer<Int>(capacity: 0)
        b.append(1)
        b.append(2)
        #expect(Array(b) == [2])
    }

    @Test func removeAllKeepsCapacity() {
        var b = RingBuffer<Int>(capacity: 2)
        b.append(1)
        b.append(2)
        b.append(3)
        b.removeAll()
        #expect(b.isEmpty)
        b.append(9)
        #expect(Array(b) == [9])
        #expect(b.capacity == 2)
    }

    @Test func mutateLastInPlace() {
        var b = RingBuffer<Int>(capacity: 2)
        b.append(1)
        b.append(2)
        b.append(3)
        b[b.index(before: b.endIndex)] = 30
        #expect(Array(b) == [2, 30])
    }
}
