import Foundation

/// Real-time ECG artifact and signal-quality detector (O(1) per sample).
struct ArtifactDetector {
    private let sampleRate: Double
    private let flatlineThresholdSeconds: Double

    // Saturation detection
    private let saturationThresholdUV: Int32 = 25_000
    private var lastSaturationTime: Timestamp?

    // Flatline / no-contact detection
    private var flatlineSamples: Int = 0
    private var prevUV: Int32 = 0
    private var hasSample: Bool = false

    // High-frequency noise detection (> 35 Hz)
    private var hfFilter: BiquadFilter
    private var hfSqAvg: MovingAverageFilter
    private var signalSqAvg: MovingAverageFilter
    private var baselineHP: BiquadFilter
    private var currentHfRMS: Double = 0
    private var currentSignalRMS: Double = 0

    // Motion from accelerometer (milli-g)
    private var currentMovementMG: Double = 0
    private var lastStrongMovementTime: Timestamp?

    // Recent beat quality tracking (last 10 s)
    private var recentBeatFlags = Deque<(t: Timestamp, isArtifact: Bool)>()

    // Current state
    private(set) var signalQuality: SignalQuality = .good
    private(set) var isCurrentlyArtifact: Bool = false
    private var lastSampleTime: Timestamp?

    init(sampleRate: Double, pauseSeconds: Double) {
        self.sampleRate = max(1.0, sampleRate)
        // Must exceed pauseSeconds so genuine sinus pauses are not misclassified as no-contact
        self.flatlineThresholdSeconds = max(6.0, pauseSeconds + 2.5)
        self.hfFilter = BiquadFilter.butterworthHighpass(cutoffHz: min(35.0, sampleRate * 0.4), sampleRate: self.sampleRate)
        let oneSec = max(1, Int(round(self.sampleRate)))
        self.hfSqAvg = MovingAverageFilter(windowSize: oneSec)
        self.signalSqAvg = MovingAverageFilter(windowSize: oneSec)
        self.baselineHP = BiquadFilter.butterworthHighpass(cutoffHz: 0.5, sampleRate: self.sampleRate)
    }

    mutating func updateMovement(mg: Double, at t: Timestamp) {
        currentMovementMG = mg
        if mg > 250.0 {
            lastStrongMovementTime = t
        }
    }

    /// Process one ECG sample. Returns `true` if this sample is part of an artifact segment.
    @discardableResult
    mutating func processSample(_ sample: ECGSample) -> Bool {
        let t = sample.t
        lastSampleTime = t

        // 1. Saturation check
        let absUV = sample.uV == Int32.min ? Int32.max : abs(sample.uV)
        let saturated = absUV >= saturationThresholdUV
        if saturated {
            lastSaturationTime = t
        }

        // 2. Flatline check (tiny sample-to-sample change)
        if hasSample {
            let diff = abs(Int64(sample.uV) - Int64(prevUV))
            if diff <= 15 {
                flatlineSamples += 1
            } else {
                flatlineSamples = 0
            }
        }
        prevUV = sample.uV
        hasSample = true

        let flatlineSeconds = Double(flatlineSamples) / sampleRate
        let isNoContact = flatlineSeconds >= flatlineThresholdSeconds

        // 3. High-frequency noise check
        let x = Double(sample.uV)
        let clean = baselineHP.process(x)
        let hf = hfFilter.process(x)
        let hfMeanSq = hfSqAvg.process(hf * hf)
        let sigMeanSq = signalSqAvg.process(clean * clean)
        currentHfRMS = hfMeanSq > 0 ? hfMeanSq.squareRoot() : 0
        currentSignalRMS = sigMeanSq > 0 ? sigMeanSq.squareRoot() : 0

        let severeHFNoise = currentHfRMS > 300.0 || (currentHfRMS > 150.0 && currentSignalRMS > 1.0 && (currentHfRMS / currentSignalRMS) > 0.65)
        let moderateHFNoise = currentHfRMS > 120.0 && currentSignalRMS > 1.0 && (currentHfRMS / currentSignalRMS) > 0.40

        // 4. Recent saturation or strong ACC movement
        let recentSat = lastSaturationTime.map { (t - $0) <= 0.25 } ?? false
        let recentStrongMove = (currentMovementMG > 250.0) || (lastStrongMovementTime.map { (t - $0) <= 0.5 } ?? false)
        let moderateMove = currentMovementMG > 100.0

        isCurrentlyArtifact = isNoContact || saturated || recentSat || severeHFNoise || recentStrongMove

        // Evict old beat quality flags
        while let first = recentBeatFlags.first, (t - first.t) > 10.0 {
            recentBeatFlags.popFirst()
        }
        let artifactBeatRatio: Double
        if recentBeatFlags.count >= 4 {
            var bad = 0
            recentBeatFlags.forEach { if $0.isArtifact { bad += 1 } }
            artifactBeatRatio = Double(bad) / Double(recentBeatFlags.count)
        } else {
            artifactBeatRatio = 0
        }

        // Update SignalQuality
        if isNoContact {
            signalQuality = .noContact
        } else if saturated || recentSat || severeHFNoise || recentStrongMove || artifactBeatRatio > 0.40 {
            signalQuality = .poor
        } else if moderateHFNoise || moderateMove || artifactBeatRatio > 0.15 {
            signalQuality = .fair
        } else {
            signalQuality = .good
        }

        return isCurrentlyArtifact
    }

    /// Evaluate whether a detected beat is an artifact.
    mutating func evaluateBeat(at t: Timestamp, amplitudeUV: Int32, rrMs: Double?) -> Bool {
        let absAmp = amplitudeUV == Int32.min ? Int32.max : abs(amplitudeUV)
        let implausibleAmp = absAmp >= saturationThresholdUV || absAmp < 40
        let implausibleShortRR = rrMs.map { $0 < 200.0 } ?? false
        let recentSat = lastSaturationTime.map { abs(t - $0) <= 0.30 } ?? false
        let recentStrongMove = (currentMovementMG > 250.0) || (lastStrongMovementTime.map { abs(t - $0) <= 0.60 } ?? false)
        let flatlineSeconds = Double(flatlineSamples) / sampleRate
        let isNoContact = flatlineSeconds >= flatlineThresholdSeconds
        let severeHF = currentHfRMS > 300.0 || (currentHfRMS > 150.0 && currentSignalRMS > 1.0 && (currentHfRMS / currentSignalRMS) > 0.65)

        let artifact = isNoContact || recentSat || recentStrongMove || severeHF || implausibleAmp || implausibleShortRR
        recentBeatFlags.append((t: t, isArtifact: artifact))
        while let first = recentBeatFlags.first, (t - first.t) > 10.0 {
            recentBeatFlags.popFirst()
        }
        return artifact
    }

    mutating func reset() {
        lastSaturationTime = nil
        flatlineSamples = 0
        prevUV = 0
        hasSample = false
        hfFilter.reset()
        hfSqAvg.reset()
        signalSqAvg.reset()
        baselineHP.reset()
        currentHfRMS = 0
        currentSignalRMS = 0
        currentMovementMG = 0
        lastStrongMovementTime = nil
        recentBeatFlags.removeAll()
        signalQuality = .good
        isCurrentlyArtifact = false
        lastSampleTime = nil
    }
}
