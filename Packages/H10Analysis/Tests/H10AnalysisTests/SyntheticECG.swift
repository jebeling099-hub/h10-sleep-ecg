import XCTest
@testable import H10Analysis

/// Deterministic seeded PRNG (LCG) for reproducible synthetic signals.
struct SeededRNG {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func nextUInt64() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }

    /// Uniform Double in [0, 1).
    mutating func nextDouble() -> Double {
        return Double(nextUInt64() >> 11) / Double(1 << 53)
    }

    mutating func nextDouble(in range: ClosedRange<Double>) -> Double {
        return range.lowerBound + nextDouble() * (range.upperBound - range.lowerBound)
    }
}

enum SyntheticBeatKind {
    case normal
    case ves
    case sves
}

struct SyntheticBeatSpec {
    let time: Double
    let kind: SyntheticBeatKind
}

enum SyntheticECG {
    /// Generate a synthetic 130 Hz ECG signal from Gaussian P/QRS/T waves.
    static func generate(
        beats: [SyntheticBeatSpec],
        durationSeconds: Double,
        sampleRate: Double = 130.0,
        startTime: Timestamp = 1_700_000_000.0,
        polarity: Double = 1.0
    ) -> [ECGSample] {
        let count = Int(ceil(durationSeconds * sampleRate))
        var samples: [ECGSample] = []
        samples.reserveCapacity(count)

        var beatCursor = 0
        for i in 0..<count {
            let relT = Double(i) / sampleRate
            // Advance cursor to keep only nearby beats (within ±0.5 s)
            while beatCursor < beats.count && beats[beatCursor].time < relT - 0.5 {
                beatCursor += 1
            }

            var val = 0.0
            var j = beatCursor
            while j < beats.count && beats[j].time <= relT + 0.5 {
                let b = beats[j]
                let dt = relT - b.time
                switch b.kind {
                case .normal, .sves:
                    val += polarity * gaussian(dt, center: -0.16, sigma: 0.025, amp: 120.0)
                    val += polarity * gaussian(dt, center: -0.028, sigma: 0.008, amp: -120.0)
                    val += polarity * gaussian(dt, center: 0.0, sigma: 0.010, amp: 1000.0)
                    val += polarity * gaussian(dt, center: 0.028, sigma: 0.009, amp: -180.0)
                    val += polarity * gaussian(dt, center: 0.24, sigma: 0.045, amp: 250.0)
                case .ves:
                    // Wide, inverted ventricular complex without preceding P wave
                    val += polarity * gaussian(dt, center: 0.0, sigma: 0.038, amp: -1100.0)
                    val += polarity * gaussian(dt, center: 0.28, sigma: 0.050, amp: 320.0)
                }
                j += 1
            }

            let clamped = max(Double(Int32.min + 1), min(Double(Int32.max - 1), val))
            samples.append(ECGSample(t: startTime + relT, uV: Int32(round(clamped))))
        }
        return samples
    }

    private static func gaussian(_ x: Double, center: Double, sigma: Double, amp: Double) -> Double {
        let d = (x - center) / sigma
        return amp * exp(-0.5 * d * d)
    }
}
