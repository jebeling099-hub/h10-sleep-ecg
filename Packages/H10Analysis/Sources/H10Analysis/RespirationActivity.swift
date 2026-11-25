import Foundation

/// Processes 25 Hz chest accelerometer data (milli-g) to estimate movement/activity
/// and respiration rate (0.1–0.5 Hz bandpass on the strongest axis when still).
struct RespirationActivityAnalyzer {
    private struct FilteredACC {
        let t: Timestamp
        let x: Double
        let y: Double
        let z: Double
        let dev: Double
    }

    private let sampleRate: Double
    private var baselineMag: Double = 1000.0
    private var initialX: Double = 0
    private var initialY: Double = 0
    private var initialZ: Double = 0
    private var hasBaseline: Bool = false

    // Bandpass 0.1–0.5 Hz (6–30 breaths/min) per axis
    private var bpX: BandpassFilter
    private var bpY: BandpassFilter
    private var bpZ: BandpassFilter

    // 45-second ring buffer for respiration rate estimation
    private var respBuffer: RingBuffer<FilteredACC>
    private var samplesSinceRespEval: Int = 0
    private let evalIntervalSamples: Int
    private let minRespWindowSamples: Int

    private(set) var currentMovementMG: Double = 0
    private(set) var currentRespirationRate: Double?

    init(sampleRate: Double) {
        self.sampleRate = max(1.0, sampleRate)
        self.bpX = BandpassFilter(lowCutoffHz: 0.10, highCutoffHz: 0.50, sampleRate: self.sampleRate)
        self.bpY = BandpassFilter(lowCutoffHz: 0.10, highCutoffHz: 0.50, sampleRate: self.sampleRate)
        self.bpZ = BandpassFilter(lowCutoffHz: 0.10, highCutoffHz: 0.50, sampleRate: self.sampleRate)
        let cap = max(25, Int(ceil(45.0 * self.sampleRate)))
        self.respBuffer = RingBuffer<FilteredACC>(capacity: cap)
        self.evalIntervalSamples = max(1, Int(round(5.0 * self.sampleRate)))
        self.minRespWindowSamples = max(10, Int(round(30.0 * self.sampleRate)))
    }

    /// Process one accelerometer sample. Returns instantaneous activity deviation (milli-g).
    @discardableResult
    mutating func process(_ sample: ACCSample) -> Double {
        let dx = Double(sample.x)
        let dy = Double(sample.y)
        let dz = Double(sample.z)
        let mag = (dx * dx + dy * dy + dz * dz).squareRoot()

        if !hasBaseline {
            baselineMag = mag
            initialX = dx
            initialY = dy
            initialZ = dz
            hasBaseline = true
        } else {
            baselineMag = 0.98 * baselineMag + 0.02 * mag
        }

        let dev = abs(mag - baselineMag)
        currentMovementMG = 0.95 * currentMovementMG + 0.05 * dev

        let fx = bpX.process(dx - initialX)
        let fy = bpY.process(dy - initialY)
        let fz = bpZ.process(dz - initialZ)
        respBuffer.append(FilteredACC(t: sample.t, x: fx, y: fy, z: fz, dev: dev))

        samplesSinceRespEval += 1
        if samplesSinceRespEval >= evalIntervalSamples {
            samplesSinceRespEval = 0
            evaluateRespiration()
        }

        return dev
    }

    private mutating func evaluateRespiration() {
        let n = respBuffer.count
        guard n >= minRespWindowSamples else { return }

        // Check stillness over window
        var sumDev = 0.0
        var sumX = 0.0, sumY = 0.0, sumZ = 0.0
        for i in 0..<n {
            let s = respBuffer[i]
            sumDev += s.dev
            sumX += s.x
            sumY += s.y
            sumZ += s.z
        }
        let meanDev = sumDev / Double(n)
        if meanDev > 40.0 {
            // Too much movement for reliable respiration estimation
            currentRespirationRate = nil
            return
        }

        let meanX = sumX / Double(n)
        let meanY = sumY / Double(n)
        let meanZ = sumZ / Double(n)

        var varX = 0.0, varY = 0.0, varZ = 0.0
        for i in 0..<n {
            let s = respBuffer[i]
            let rx = s.x - meanX
            let ry = s.y - meanY
            let rz = s.z - meanZ
            varX += rx * rx
            varY += ry * ry
            varZ += rz * rz
        }
        varX /= Double(n)
        varY /= Double(n)
        varZ /= Double(n)

        // Pick axis with maximum 0.1–0.5 Hz power
        let axis: Int
        let maxVar: Double
        if varX >= varY && varX >= varZ {
            axis = 0; maxVar = varX
        } else if varY >= varZ {
            axis = 1; maxVar = varY
        } else {
            axis = 2; maxVar = varZ
        }

        let std = maxVar.squareRoot()
        guard std >= 0.5 else {
            currentRespirationRate = nil
            return
        }

        let meanAxis = axis == 0 ? meanX : (axis == 1 ? meanY : meanZ)
        let hyst = 0.25 * std

        // Count upward zero-crossings with hysteresis
        var state = 0 // -1 below -hyst, +1 above +hyst
        var crossingTimes: [Timestamp] = []
        let minBreathInterval = 1.8 // max ~33 breaths/min

        for i in 0..<n {
            let s = respBuffer[i]
            let rawVal = (axis == 0 ? s.x : (axis == 1 ? s.y : s.z)) - meanAxis
            if rawVal < -hyst {
                state = -1
            } else if rawVal > hyst {
                if state == -1 {
                    if let last = crossingTimes.last {
                        if (s.t - last) >= minBreathInterval {
                            crossingTimes.append(s.t)
                        }
                    } else {
                        crossingTimes.append(s.t)
                    }
                }
                state = 1
            }
        }

        guard crossingTimes.count >= 3 else { return }
        let span = crossingTimes[crossingTimes.count - 1] - crossingTimes[0]
        guard span > 5.0 else { return }
        let bpm = (Double(crossingTimes.count - 1) / span) * 60.0

        if bpm >= 5.0 && bpm <= 35.0 {
            if let prev = currentRespirationRate {
                currentRespirationRate = 0.35 * bpm + 0.65 * prev
            } else {
                currentRespirationRate = bpm
            }
        }
    }

    mutating func reset() {
        baselineMag = 1000.0
        initialX = 0
        initialY = 0
        initialZ = 0
        hasBaseline = false
        bpX.reset()
        bpY.reset()
        bpZ.reset()
        respBuffer.removeAll()
        samplesSinceRespEval = 0
        currentMovementMG = 0
        currentRespirationRate = nil
    }
}
