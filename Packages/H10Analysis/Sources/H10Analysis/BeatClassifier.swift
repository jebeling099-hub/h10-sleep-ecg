import Foundation

/// Adaptive beat classifier distinguishing normal beats, VES, SVES, and artifacts.
/// Uses running median RR, prematurity, compensatory pause tracking, ±100 ms QRS template correlation,
/// and QRS width estimation.
struct BeatClassifier {
    let halfWindowSamples: Int
    private let sampleRate: Double
    private let learningTarget: Int = 10

    // Running normal QRS template (±100 ms)
    private var template: [Double] = []
    private var normalBeatCount: Int = 0
    private var normalQRSWidthMs: Double = 80.0

    // Running median of normal RR intervals (last 15)
    private var normalRRs: RingBuffer<Double>
    private var previousBeatClass: BeatClass = .unknown
    private var previousRRMs: Double?

    init(sampleRate: Double) {
        self.sampleRate = max(1.0, sampleRate)
        self.halfWindowSamples = max(4, Int(round(0.100 * self.sampleRate)))
        self.normalRRs = RingBuffer<Double>(capacity: 15)
    }

    var localMedianRRMs: Double? {
        guard !normalRRs.isEmpty else { return nil }
        var vals = normalRRs.toArray()
        vals.sort()
        let mid = vals.count / 2
        if vals.count % 2 == 1 {
            return vals[mid]
        } else {
            return 0.5 * (vals[mid - 1] + vals[mid])
        }
    }

    mutating func classify(
        peak: DetectedRPeak,
        waveform: [Double]?,
        isArtifact: Bool
    ) -> Beat {
        if isArtifact {
            previousBeatClass = .artifact
            previousRRMs = peak.rrMs
            return Beat(t: peak.timestamp, rrMs: peak.rrMs, amplitudeUV: peak.amplitudeUV, cls: .artifact)
        }

        let qrsWidth = waveform.map { estimateQRSWidthMs($0) } ?? normalQRSWidthMs
        let medianRR = localMedianRRMs

        // Check if previous beat was an ectopic (so current beat may end a compensatory pause)
        let afterEctopic = (previousBeatClass == .ves || previousBeatClass == .sves)
        let plausibleRR = peak.rrMs.map { $0 >= 280.0 && $0 <= 2000.0 } ?? false

        // Learning phase: build normal template over first ~10 non-artifact beats
        if normalBeatCount < learningTarget {
            let isVeryPremature: Bool
            if let rr = peak.rrMs, let med = medianRR, normalRRs.count >= 4 {
                isVeryPremature = (rr / med) < 0.75
            } else {
                isVeryPremature = false
            }

            if !isVeryPremature {
                if let wave = waveform {
                    updateLearningTemplate(wave: wave, widthMs: qrsWidth)
                }
                if plausibleRR, let rr = peak.rrMs, !afterEctopic {
                    normalRRs.append(rr)
                }
                normalBeatCount += 1
                previousBeatClass = .normal
                previousRRMs = peak.rrMs
                return Beat(t: peak.timestamp, rrMs: peak.rrMs, amplitudeUV: peak.amplitudeUV, cls: .normal)
            }
            // Fall through to classify if clearly premature even during late learning
        }

        // Compute morphology features against normal template
        let correlation: Double
        if let wave = waveform, !template.isEmpty, wave.count == template.count {
            correlation = maxLagCorrelation(wave, template, maxLag: 2)
        } else {
            correlation = 1.0
        }

        let rrRatio: Double?
        if let rr = peak.rrMs, let med = medianRR, med > 0 {
            rrRatio = rr / med
        } else {
            rrRatio = nil
        }

        let isPremature = rrRatio.map { $0 < 0.85 } ?? false
        let isWideQRS = qrsWidth > max(115.0, normalQRSWidthMs * 1.40)
        let isAbnormalMorphology = correlation < 0.80

        let cls: BeatClass
        if isPremature {
            if isAbnormalMorphology || isWideQRS {
                cls = .ves
            } else {
                cls = .sves
            }
        } else if correlation < 0.65 && qrsWidth > max(120.0, normalQRSWidthMs * 1.45) {
            // Non-premature ventricular escape / late-diastolic VES
            cls = .ves
        } else {
            cls = .normal
            // Slowly adapt template and normal RR median
            if let wave = waveform, wave.count == template.count, correlation >= 0.82 {
                for i in 0..<template.count {
                    template[i] = 0.95 * template[i] + 0.05 * wave[i]
                }
                normalQRSWidthMs = 0.95 * normalQRSWidthMs + 0.05 * qrsWidth
            }
            if plausibleRR, let rr = peak.rrMs, !afterEctopic {
                // Avoid letting a compensatory pause distort the normal RR median
                if let med = medianRR {
                    if rr <= med * 1.45 {
                        normalRRs.append(rr)
                    }
                } else {
                    normalRRs.append(rr)
                }
            }
        }

        previousBeatClass = cls
        previousRRMs = peak.rrMs
        return Beat(t: peak.timestamp, rrMs: peak.rrMs, amplitudeUV: peak.amplitudeUV, cls: cls)
    }

    private mutating func updateLearningTemplate(wave: [Double], widthMs: Double) {
        if template.isEmpty {
            template = wave
            normalQRSWidthMs = widthMs
        } else if template.count == wave.count {
            let n = Double(normalBeatCount)
            let wNew = 1.0 / (n + 1.0)
            let wOld = 1.0 - wNew
            for i in 0..<template.count {
                template[i] = wOld * template[i] + wNew * wave[i]
            }
            normalQRSWidthMs = wOld * normalQRSWidthMs + wNew * widthMs
        }
    }

    /// Estimate QRS width in ms as the contiguous span around the peak where |x| >= 20% of peak |x|.
    private func estimateQRSWidthMs(_ wave: [Double]) -> Double {
        guard !wave.isEmpty else { return 80.0 }
        let center = wave.count / 2
        let searchLow = max(0, center - 2)
        let searchHigh = min(wave.count - 1, center + 2)
        var peakIdx = center
        var peakAbs = abs(wave[center])
        for i in searchLow...searchHigh {
            let a = abs(wave[i])
            if a > peakAbs {
                peakAbs = a
                peakIdx = i
            }
        }
        guard peakAbs > 1e-6 else { return 80.0 }
        let threshold = 0.20 * peakAbs

        var left = peakIdx
        while left > 0 && abs(wave[left - 1]) >= threshold {
            left -= 1
        }
        var right = peakIdx
        while right < wave.count - 1 && abs(wave[right + 1]) >= threshold {
            right += 1
        }
        let widthSamples = right - left + 1
        return (Double(widthSamples) / sampleRate) * 1000.0
    }

    /// Maximum Pearson correlation between `a` and `b` over small integer lags in `-maxLag...maxLag`.
    private func maxLagCorrelation(_ a: [Double], _ b: [Double], maxLag: Int) -> Double {
        let n = min(a.count, b.count)
        guard n >= 5 else { return 1.0 }
        var best = -1.0
        for lag in -maxLag...maxLag {
            let startA = max(0, lag)
            let startB = max(0, -lag)
            let len = n - abs(lag)
            guard len >= 5 else { continue }

            var meanA = 0.0
            var meanB = 0.0
            for i in 0..<len {
                meanA += a[startA + i]
                meanB += b[startB + i]
            }
            meanA /= Double(len)
            meanB /= Double(len)

            var num = 0.0
            var denA = 0.0
            var denB = 0.0
            for i in 0..<len {
                let da = a[startA + i] - meanA
                let db = b[startB + i] - meanB
                num += da * db
                denA += da * da
                denB += db * db
            }
            let denom = (denA * denB).squareRoot()
            let r = denom > 1e-9 ? (num / denom) : 0.0
            if r > best {
                best = r
            }
        }
        return best
    }

    mutating func reset() {
        template.removeAll()
        normalBeatCount = 0
        normalQRSWidthMs = 80.0
        normalRRs.removeAll()
        previousBeatClass = .unknown
        previousRRMs = nil
    }
}
