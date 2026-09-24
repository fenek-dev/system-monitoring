// W0b stub (ARCHITECTURE §5.7). W1 replaces this file.

public struct RingBuffer<Element>: RandomAccessCollection {
    private var storage: [Element] = []
    private let capacity: Int

    public init(capacity: Int) {
        self.capacity = capacity
    }

    public mutating func append(_ e: Element) {
        storage.append(e)
        if storage.count > capacity { storage.removeFirst(storage.count - capacity) }
    }

    public var startIndex: Int { storage.startIndex }
    public var endIndex: Int { storage.endIndex }
    public subscript(position: Int) -> Element { storage[position] }
}
