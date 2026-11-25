import Foundation

/// A refined R-peak detected by the streaming Pan-Tompkins detector.
struct DetectedRPeak {
    let timestamp: Timestamp
    let sampleIndex: Int64
    let amplitudeUV: Int32
    let rrMs: Double?
}

/// Streaming Pan-Tompkins R-peak detector for 130 Hz (or configurable) ECG.
/// Supports both positive and negative R-wave polarities via raw-signal peak refinement.
struct RPeakDetector {
    private struct BufferedSample {
        let index: Int64
        let t: Timestamp
        let rawUV: Int32
        let cleanRaw: Double
    }

    private struct SubthresholdPeak {
        let mwiVal: Double
        let mwiSampleIndex: Int64
    }

    private let sampleRate: Double
    private let refractorySeconds: Double = 0.200
    private let minMwiThreshold: Double = 40.0
    private let refinementMaxLagSamples: Int

    // Pan-Tompkins filter cascade
    private var baselineHP: BiquadFilter
    private var bandpass: BandpassFilter
    private var derivative: FivePointDerivative
    private var mwiFilter: MovingAverageFilter

    // Recent raw/baseline-corrected samples for peak refinement & QRS extraction
    private var rawBuffer: RingBuffer<BufferedSample>
    private var sampleIndex: Int64 = -1
    private var initialOffset: Double?

    // MWI local peak tracker
    private var peakVal: Double = 0
    private var peakSampleIdx: Int64 = 0
    private var decliningCount: Int = 0
    private var prevMwi: Double = 0

    // Adaptive Pan-Tompkins thresholds
    private var spki: Double = 0
    private var npki: Double = 0
    private var hasInitialized: Bool = false

    // RR tracking for search-back
    private var lastBeatTime: Timestamp?
    private var lastBeatSampleIdx: Int64?
    private var recentRRs: RingBuffer<Double>
    private var subthresholdPeaks = Deque<SubthresholdPeak>()

    init(sampleRate: Double) {
        self.sampleRate = max(1.0, sampleRate)
        self.refinementMaxLagSamples = max(8, Int(round(0.20 * self.sampleRate)))
        self.baselineHP = BiquadFilter.butterworthHighpass(cutoffHz: 0.5, sampleRate: self.sampleRate)
        self.bandpass = BandpassFilter(lowCutoffHz: 5.0, highCutoffHz: 15.0, sampleRate: self.sampleRate)
        self.derivative = FivePointDerivative()
        let mwiWin = max(1, Int(round(0.150 * self.sampleRate)))
        self.mwiFilter = MovingAverageFilter(windowSize: mwiWin)
        // Store ~1.0 second of clean raw samples for refinement and ±100 ms QRS extraction
        let bufCap = max(64, Int(ceil(1.0 * self.sampleRate)))
        self.rawBuffer = RingBuffer<BufferedSample>(capacity: bufCap)
        self.recentRRs = RingBuffer<Double>(capacity: 8)
    }

    var currentSampleIndex: Int64 { sampleIndex }

    /// Extract a centered waveform of length `2 * halfWindow + 1` around `centerIndex` from `rawBuffer`.
    /// Returns `nil` if the required samples are not yet (or no longer) in the buffer.
    func extractWaveform(centerIndex: Int64, halfWindow: Int) -> [Double]? {
        guard !rawBuffer.isEmpty else { return nil }
        let oldestIdx = rawBuffer[0].index
        let newestIdx = rawBuffer[rawBuffer.count - 1].index
        let startIdx = centerIndex - Int64(halfWindow)
        let endIdx = centerIndex + Int64(halfWindow)
        guard startIdx >= oldestIdx && endIdx <= newestIdx else { return nil }

        let total = 2 * halfWindow + 1
        var wave: [Double] = []
        wave.reserveCapacity(total)
        let offset = Int(startIdx - oldestIdx)
        for i in 0..<total {
            wave.append(rawBuffer[offset + i].cleanRaw)
        }
        return wave
    }

    /// Feed one ECG sample. Returns 0, 1, or (rarely, on search-back) 2 detected R-peaks.
    mutating func process(_ sample: ECGSample) -> [DetectedRPeak] {
        sampleIndex += 1
        let rawDouble = Double(sample.uV)
        if initialOffset == nil {
            initialOffset = rawDouble
        }
        let centered = rawDouble - (initialOffset ?? 0)
        let cleanRaw = baselineHP.process(centered)
        rawBuffer.append(BufferedSample(index: sampleIndex, t: sample.t, rawUV: sample.uV, cleanRaw: cleanRaw))

        let bp = bandpass.process(centered)
        let der = derivative.process(bp)
        let sq = der * der
        let mwi = mwiFilter.process(sq)

        var detected: [DetectedRPeak] = []

        // Track local MWI peak
        if mwi > peakVal {
            peakVal = mwi
            peakSampleIdx = sampleIndex
            decliningCount = 0
        } else if peakVal > 0 {
            if mwi < prevMwi {
                decliningCount += 1
            }
            if mwi < peakVal * 0.5 || decliningCount >= 4 {
                if let beat = evaluateCandidatePeak(mwiVal: peakVal, mwiSampleIndex: peakSampleIdx) {
                    detected.append(beat)
                }
                peakVal = 0
                decliningCount = 0
            }
        }
        prevMwi = mwi

        // Search-back if we have gone > 1.66 * rrAverage without a beat
        if let lastTime = lastBeatTime, let rrAvg = averageRRSeconds() {
            let elapsed = sample.t - lastTime
            if elapsed > max(1.66 * rrAvg, 0.8) && elapsed < 2.2 {
                if let sbBeat = performSearchBack() {
                    detected.append(sbBeat)
                }
            }
        }

        // Prune old subthreshold peaks (> 2.5 s old)
        let maxAgeSamples = Int64(2.5 * sampleRate)
        while let first = subthresholdPeaks.first, (sampleIndex - first.mwiSampleIndex) > maxAgeSamples {
            subthresholdPeaks.popFirst()
        }

        return detected
    }

    private mutating func evaluateCandidatePeak(mwiVal: Double, mwiSampleIndex: Int64) -> DetectedRPeak? {
        if !hasInitialized {
            guard mwiVal >= minMwiThreshold else { return nil }
            spki = mwiVal
            npki = mwiVal * 0.1
            hasInitialized = true
            return acceptPeak(mwiVal: mwiVal, mwiSampleIndex: mwiSampleIndex, isSearchBack: false)
        }

        let thresholdI1 = max(npki + 0.25 * (spki - npki), minMwiThreshold)
        if mwiVal >= thresholdI1 {
            // Check refractory and T-wave discrimination before accepting
            if let refined = refinePeak(around: mwiSampleIndex) {
                if let lastTime = lastBeatTime {
                    let dt = refined.t - lastTime
                    if dt < refractorySeconds {
                        return nil
                    }
                    // T-wave discrimination: short interval with small MWI compared to SPKI
                    if dt < 0.320 && mwiVal < 0.35 * spki {
                        npki = 0.125 * mwiVal + 0.875 * npki
                        return nil
                    }
                }
                return commitRefinedBeat(refined, mwiVal: mwiVal, isSearchBack: false)
            }
            return nil
        } else {
            // Store for potential search-back
            if mwiVal >= minMwiThreshold * 0.5 {
                subthresholdPeaks.append(SubthresholdPeak(mwiVal: mwiVal, mwiSampleIndex: mwiSampleIndex))
            }
            npki = 0.125 * mwiVal + 0.875 * npki
            return nil
        }
    }

    private mutating func performSearchBack() -> DetectedRPeak? {
        guard hasInitialized, let lastIdx = lastBeatSampleIdx else { return nil }
        let thresholdI1 = max(npki + 0.25 * (spki - npki), minMwiThreshold)
        let thresholdI2 = max(0.5 * thresholdI1, minMwiThreshold)
        let refractorySamples = Int64(round(refractorySeconds * sampleRate))

        var best: SubthresholdPeak?
        subthresholdPeaks.forEach { candidate in
            if candidate.mwiSampleIndex > lastIdx + refractorySamples && candidate.mwiVal >= thresholdI2 {
                if best == nil || candidate.mwiVal > best!.mwiVal {
                    best = candidate
                }
            }
        }

        guard let chosen = best else { return nil }
        // Clear candidates up to chosen
        while let first = subthresholdPeaks.first, first.mwiSampleIndex <= chosen.mwiSampleIndex {
            subthresholdPeaks.popFirst()
        }
        return acceptPeak(mwiVal: chosen.mwiVal, mwiSampleIndex: chosen.mwiSampleIndex, isSearchBack: true)
    }

    private mutating func acceptPeak(mwiVal: Double, mwiSampleIndex: Int64, isSearchBack: Bool) -> DetectedRPeak? {
        guard let refined = refinePeak(around: mwiSampleIndex) else { return nil }
        if let lastTime = lastBeatTime, (refined.t - lastTime) < refractorySeconds {
            return nil
        }
        return commitRefinedBeat(refined, mwiVal: mwiVal, isSearchBack: isSearchBack)
    }

    private mutating func commitRefinedBeat(_ refined: BufferedSample, mwiVal: Double, isSearchBack: Bool) -> DetectedRPeak {
        if isSearchBack {
            spki = 0.25 * mwiVal + 0.75 * spki
        } else {
            spki = 0.125 * mwiVal + 0.875 * spki
        }

        let rrMs: Double?
        if let lastTime = lastBeatTime {
            let dtMs = (refined.t - lastTime) * 1000.0
            rrMs = dtMs > 0 ? dtMs : nil
            if let rr = rrMs, rr >= 280.0 && rr <= 2000.0 {
                recentRRs.append(rr)
            }
        } else {
            rrMs = nil
        }

        lastBeatTime = refined.t
        lastBeatSampleIdx = refined.index

        return DetectedRPeak(
            timestamp: refined.t,
            sampleIndex: refined.index,
            amplitudeUV: refined.rawUV,
            rrMs: rrMs
        )
    }

    /// Search raw baseline-removed signal in `[mwiSampleIndex - refinementMaxLagSamples, mwiSampleIndex]`
    /// for the maximum absolute deflection (handles both positive and negative R-waves).
    private func refinePeak(around mwiSampleIndex: Int64) -> BufferedSample? {
        guard !rawBuffer.isEmpty else { return nil }
        let oldestIdx = rawBuffer[0].index
        let newestIdx = rawBuffer[rawBuffer.count - 1].index

        let searchStart = max(oldestIdx, mwiSampleIndex - Int64(refinementMaxLagSamples))
        let searchEnd = min(newestIdx, mwiSampleIndex)
        guard searchStart <= searchEnd else { return nil }

        let startOffset = Int(searchStart - oldestIdx)
        let endOffset = Int(searchEnd - oldestIdx)

        var bestSample = rawBuffer[startOffset]
        var bestAbs = abs(bestSample.cleanRaw)
        if startOffset < endOffset {
            for i in (startOffset + 1)...endOffset {
                let s = rawBuffer[i]
                let a = abs(s.cleanRaw)
                if a > bestAbs {
                    bestAbs = a
                    bestSample = s
                }
            }
        }
        return bestSample
    }

    private func averageRRSeconds() -> Double? {
        guard recentRRs.count >= 2 else { return nil }
        var sum = 0.0
        for i in 0..<recentRRs.count {
            sum += recentRRs[i]
        }
        return (sum / Double(recentRRs.count)) / 1000.0
    }

    mutating func reset() {
        baselineHP.reset()
        bandpass.reset()
        derivative.reset()
        mwiFilter.reset()
        rawBuffer.removeAll()
        sampleIndex = -1
        initialOffset = nil
        peakVal = 0
        peakSampleIdx = 0
        decliningCount = 0
        prevMwi = 0
        spki = 0
        npki = 0
        hasInitialized = false
        lastBeatTime = nil
        lastBeatSampleIdx = nil
        recentRRs.removeAll()
        subthresholdPeaks.removeAll()
    }
}
