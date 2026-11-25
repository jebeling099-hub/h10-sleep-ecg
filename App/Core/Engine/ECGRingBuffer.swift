import Foundation
import H10Analysis

/// Thread-safe ring buffer for recent ECG samples (~30 s at 130 Hz).
/// Written on the BLE/analysis queue and read on the main thread for ~30 fps rendering.
final class ECGRingBuffer {
    private let lock = NSLock()
    private var storage: [ECGSample]
    private var head: Int = 0
    private var count: Int = 0
    private let capacity: Int

    init(capacity: Int = 4500) {
        self.capacity = max(1, capacity)
        self.storage = Array(repeating: ECGSample(t: 0, uV: 0), count: max(1, capacity))
    }

    func append(_ samples: [ECGSample]) {
        guard !samples.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        for sample in samples {
            storage[head] = sample
            head = (head + 1) % capacity
            if count < capacity {
                count += 1
            }
        }
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        head = 0
        count = 0
    }

    /// Returns samples from the last `seconds` relative to the newest sample in the buffer.
    func window(seconds: Double) -> [ECGSample] {
        guard seconds > 0 else { return [] }
        lock.lock()
        defer { lock.unlock() }

        guard count > 0 else { return [] }

        let newestIndex = (head - 1 + capacity) % capacity
        let newestTimestamp = storage[newestIndex].t
        let cutoff = newestTimestamp - seconds

        var result: [ECGSample] = []
        result.reserveCapacity(min(count, Int(seconds * 140) + 16))

        let startIndex = (head - count + capacity) % capacity
        for offset in 0..<count {
            let idx = (startIndex + offset) % capacity
            let sample = storage[idx]
            if sample.t >= cutoff {
                result.append(sample)
            }
        }
        return result
    }
}
