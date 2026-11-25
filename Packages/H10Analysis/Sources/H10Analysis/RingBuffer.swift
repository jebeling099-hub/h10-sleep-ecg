import Foundation

/// Fixed-capacity circular buffer with O(1) append and indexed access.
struct RingBuffer<Element> {
    private var storage: [Element?]
    private var head: Int = 0
    private(set) var count: Int = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        self.storage = Array(repeating: nil, count: self.capacity)
    }

    var isEmpty: Bool { count == 0 }
    var isFull: Bool { count == capacity }

    mutating func append(_ element: Element) {
        let writeIndex = (head + count) % capacity
        storage[writeIndex] = element
        if count == capacity {
            head = (head + 1) % capacity
        } else {
            count += 1
        }
    }

    /// 0 is the oldest element, `count - 1` is the newest.
    subscript(index: Int) -> Element {
        precondition(index >= 0 && index < count, "RingBuffer index out of bounds")
        return storage[(head + index) % capacity]!
    }

    var first: Element? {
        guard count > 0 else { return nil }
        return storage[head]
    }

    var last: Element? {
        guard count > 0 else { return nil }
        return storage[(head + count - 1) % capacity]
    }

    mutating func removeAll() {
        for i in 0..<storage.count {
            storage[i] = nil
        }
        head = 0
        count = 0
    }

    func toArray() -> [Element] {
        var result: [Element] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            result.append(storage[(head + i) % capacity]!)
        }
        return result
    }
}

/// Unbounded queue with O(1) amortized append and popFirst (avoids O(n) Array.removeFirst).
struct Deque<Element> {
    private var storage: [Element?] = []
    private var head: Int = 0

    var count: Int { storage.count - head }
    var isEmpty: Bool { count == 0 }

    var first: Element? {
        guard head < storage.count else { return nil }
        return storage[head]
    }

    var last: Element? {
        guard head < storage.count else { return nil }
        return storage[storage.count - 1]
    }

    mutating func append(_ element: Element) {
        storage.append(element)
    }

    @discardableResult
    mutating func popFirst() -> Element? {
        guard head < storage.count, let element = storage[head] else { return nil }
        storage[head] = nil
        head += 1
        if head >= 64 && head * 2 >= storage.count {
            storage.removeFirst(head)
            head = 0
        }
        return element
    }

    mutating func removeAll() {
        storage.removeAll(keepingCapacity: false)
        head = 0
    }

    subscript(index: Int) -> Element {
        precondition(index >= 0 && index < count, "Deque index out of bounds")
        return storage[head + index]!
    }

    func forEach(_ body: (Element) -> Void) {
        guard head < storage.count else { return }
        for i in head..<storage.count {
            if let el = storage[i] {
                body(el)
            }
        }
    }

    func toArray() -> [Element] {
        var result: [Element] = []
        result.reserveCapacity(count)
        for i in head..<storage.count {
            if let el = storage[i] {
                result.append(el)
            }
        }
        return result
    }
}
