import Foundation

/// Direct Form II Transposed second-order IIR (biquad) filter. O(1) per sample.
struct BiquadFilter {
    let b0: Double
    let b1: Double
    let b2: Double
    let a1: Double
    let a2: Double

    private var z1: Double = 0
    private var z2: Double = 0

    init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    /// 2nd-order Butterworth low-pass filter.
    static func butterworthLowpass(cutoffHz: Double, sampleRate: Double) -> BiquadFilter {
        let clampedFc = min(max(cutoffHz, 0.001), sampleRate * 0.45)
        let k = tan(Double.pi * clampedFc / sampleRate)
        let k2 = k * k
        let sqrt2 = 2.0.squareRoot()
        let norm = 1.0 / (1.0 + sqrt2 * k + k2)
        let b0 = k2 * norm
        let b1 = 2.0 * b0
        let b2 = b0
        let a1 = 2.0 * (k2 - 1.0) * norm
        let a2 = (1.0 - sqrt2 * k + k2) * norm
        return BiquadFilter(b0: b0, b1: b1, b2: b2, a1: a1, a2: a2)
    }

    /// 2nd-order Butterworth high-pass filter.
    static func butterworthHighpass(cutoffHz: Double, sampleRate: Double) -> BiquadFilter {
        let clampedFc = min(max(cutoffHz, 0.001), sampleRate * 0.45)
        let k = tan(Double.pi * clampedFc / sampleRate)
        let k2 = k * k
        let sqrt2 = 2.0.squareRoot()
        let norm = 1.0 / (1.0 + sqrt2 * k + k2)
        let b0 = norm
        let b1 = -2.0 * b0
        let b2 = b0
        let a1 = 2.0 * (k2 - 1.0) * norm
        let a2 = (1.0 - sqrt2 * k + k2) * norm
        return BiquadFilter(b0: b0, b1: b1, b2: b2, a1: a1, a2: a2)
    }

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    mutating func reset() {
        z1 = 0
        z2 = 0
    }
}

/// Cascaded 2nd-order Butterworth high-pass + low-pass bandpass filter.
struct BandpassFilter {
    private var hp: BiquadFilter
    private var lp: BiquadFilter

    init(lowCutoffHz: Double, highCutoffHz: Double, sampleRate: Double) {
        self.hp = BiquadFilter.butterworthHighpass(cutoffHz: lowCutoffHz, sampleRate: sampleRate)
        self.lp = BiquadFilter.butterworthLowpass(cutoffHz: highCutoffHz, sampleRate: sampleRate)
    }

    mutating func process(_ x: Double) -> Double {
        return lp.process(hp.process(x))
    }

    mutating func reset() {
        hp.reset()
        lp.reset()
    }
}

/// Standard Pan-Tompkins 5-point derivative filter:
/// y[n] = (2*x[n] + x[n-1] - x[n-3] - 2*x[n-4]) / 8
struct FivePointDerivative {
    private var x1: Double = 0
    private var x2: Double = 0
    private var x3: Double = 0
    private var x4: Double = 0
    private var sampleCount: Int = 0

    mutating func process(_ x: Double) -> Double {
        sampleCount += 1
        let y: Double
        if sampleCount < 5 {
            y = 0
        } else {
            y = (2.0 * x + x1 - x3 - 2.0 * x4) * 0.125
        }
        x4 = x3
        x3 = x2
        x2 = x1
        x1 = x
        return y
    }

    mutating func reset() {
        x1 = 0; x2 = 0; x3 = 0; x4 = 0
        sampleCount = 0
    }
}

/// O(1) moving-window average filter with periodic sum recalibration to prevent drift.
struct MovingAverageFilter {
    private var buffer: [Double]
    private var index: Int = 0
    private var count: Int = 0
    private var sum: Double = 0
    private var stepsSinceRecalc: Int = 0
    let windowSize: Int

    init(windowSize: Int) {
        self.windowSize = max(1, windowSize)
        self.buffer = Array(repeating: 0.0, count: self.windowSize)
    }

    mutating func process(_ x: Double) -> Double {
        if count < windowSize {
            buffer[index] = x
            sum += x
            count += 1
        } else {
            sum -= buffer[index]
            buffer[index] = x
            sum += x
        }
        index = (index + 1) % windowSize
        stepsSinceRecalc += 1
        if stepsSinceRecalc >= 10_000 {
            var recomputed = 0.0
            for i in 0..<count {
                recomputed += buffer[i]
            }
            sum = recomputed
            stepsSinceRecalc = 0
        }
        return sum / Double(count)
    }

    mutating func reset() {
        for i in 0..<buffer.count {
            buffer[i] = 0
        }
        index = 0
        count = 0
        sum = 0
        stepsSinceRecalc = 0
    }
}
