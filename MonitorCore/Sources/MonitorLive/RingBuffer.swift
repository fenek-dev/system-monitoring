/// Fixed-capacity FIFO: appending to a full buffer overwrites the oldest element.
/// Indices are logical (0 = oldest), so it reads like an ordinary array.
public struct RingBuffer<Element>: RandomAccessCollection, MutableCollection {
    public let capacity: Int
    private var storage: ContiguousArray<Element> = []
    /// Physical index of the oldest element once the storage is full.
    private var head = 0

    /// `capacity` < 1 is clamped to 1.
    public init(capacity: Int) {
        self.capacity = Swift.max(1, capacity)
        storage.reserveCapacity(self.capacity)
    }

    public mutating func append(_ e: Element) {
        if storage.count < capacity {
            storage.append(e)
        } else {
            storage[head] = e
            head = (head + 1) % capacity
        }
    }

    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
    }

    public var startIndex: Int { 0 }
    public var endIndex: Int { storage.count }

    public subscript(position: Int) -> Element {
        get { storage[physical(position)] }
        set { storage[physical(position)] = newValue }
    }

    /// Base address of the backing storage (tests: detect copy-on-write reallocation).
    var storageAddress: UnsafeRawPointer? {
        storage.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) }
    }

    @inline(__always)
    private func physical(_ i: Int) -> Int {
        precondition(i >= 0 && i < storage.count, "RingBuffer index \(i) out of range 0..<\(storage.count)")
        return (head + i) % storage.count
    }
}

extension RingBuffer: Sendable where Element: Sendable {}
extension RingBuffer: Equatable where Element: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.capacity == rhs.capacity && lhs.elementsEqual(rhs) }
}
