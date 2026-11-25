import Foundation

/// Aggregates real-time beats, ECG quality, accelerometer activity, and respiration
/// into fixed-length (default 30 s) `EpochSummary` records with `source == .stream`.
struct EpochAggregator {
    var epochDuration: Double

    private var currentStart: Timestamp?
    private var completedEpochs: [EpochSummary] = []

    // Current epoch accumulators
    private var cleanRRs: [Double] = []
    private var vesCount: Int = 0
    private var svesCount: Int = 0
    private var totalBeats: Int = 0
    private var artifactBeats: Int = 0
    private var totalEcgSamples: Int = 0
    private var artifactEcgSamples: Int = 0
    private var activitySum: Double = 0
    private var activityCount: Int = 0
    private var respSum: Double = 0
    private var respCount: Int = 0

    init(epochDuration: Double) {
        self.epochDuration = max(1.0, epochDuration)
    }

    mutating func recordEcgSample(at t: Timestamp, isArtifact: Bool) {
        advanceIfNeeded(to: t)
        totalEcgSamples += 1
        if isArtifact {
            artifactEcgSamples += 1
        }
    }

    mutating func recordBeat(_ beat: Beat) {
        advanceIfNeeded(to: beat.t)
        totalBeats += 1
        switch beat.cls {
        case .normal:
            if let rr = beat.rrMs, rr >= 250.0 && rr <= 2500.0 {
                cleanRRs.append(rr)
            }
        case .ves:
            vesCount += 1
        case .sves:
            svesCount += 1
        case .artifact:
            artifactBeats += 1
        case .unknown:
            if let rr = beat.rrMs, rr >= 250.0 && rr <= 2500.0 {
                cleanRRs.append(rr)
            }
        }
    }

    mutating func recordActivity(_ devMG: Double, respirationRate: Double?, at t: Timestamp) {
        advanceIfNeeded(to: t)
        activitySum += devMG
        activityCount += 1
        if let resp = respirationRate {
            respSum += resp
            respCount += 1
        }
    }

    mutating func drainEpochs() -> [EpochSummary] {
        let out = completedEpochs
        completedEpochs.removeAll(keepingCapacity: true)
        return out
    }

    private mutating func advanceIfNeeded(to t: Timestamp) {
        guard let start = currentStart else {
            currentStart = t
            return
        }
        guard t >= start + epochDuration else { return }

        finalizeCurrentEpoch(start: start)

        // Advance cleanly without generating empty epochs across large gaps
        let nextStart = start + epochDuration
        if (t - nextStart) < epochDuration {
            currentStart = nextStart
        } else {
            currentStart = t
        }
    }

    private mutating func finalizeCurrentEpoch(start: Timestamp) {
        let meanHR: Double?
        let minHR: Double?
        let rmssd: Double?

        if !cleanRRs.isEmpty {
            let meanRR = cleanRRs.reduce(0.0, +) / Double(cleanRRs.count)
            meanHR = meanRR > 1.0 ? (60_000.0 / meanRR) : nil
            if let maxRR = cleanRRs.max(), maxRR > 1.0 {
                minHR = 60_000.0 / maxRR
            } else {
                minHR = nil
            }
            rmssd = HRVCalculator.rmssd(cleanRRs)
        } else {
            meanHR = nil
            minHR = nil
            rmssd = nil
        }

        let activity = activityCount > 0 ? (activitySum / Double(activityCount)) : nil
        let resp = respCount > 0 ? (respSum / Double(respCount)) : nil

        let artifactFraction: Double
        if totalEcgSamples > 0 {
            artifactFraction = min(1.0, max(0.0, Double(artifactEcgSamples) / Double(totalEcgSamples)))
        } else if totalBeats > 0 {
            artifactFraction = min(1.0, max(0.0, Double(artifactBeats) / Double(totalBeats)))
        } else {
            artifactFraction = 0.0
        }

        completedEpochs.append(EpochSummary(
            start: start,
            duration: epochDuration,
            meanHR: meanHR,
            minHR: minHR,
            rmssd: rmssd,
            activity: activity,
            respirationRate: resp,
            vesCount: vesCount,
            svesCount: svesCount,
            artifactFraction: artifactFraction,
            source: .stream
        ))

        clearAccumulators()
    }

    private mutating func clearAccumulators() {
        cleanRRs.removeAll(keepingCapacity: true)
        vesCount = 0
        svesCount = 0
        totalBeats = 0
        artifactBeats = 0
        totalEcgSamples = 0
        artifactEcgSamples = 0
        activitySum = 0
        activityCount = 0
        respSum = 0
        respCount = 0
    }

    mutating func reset() {
        currentStart = nil
        completedEpochs.removeAll()
        clearAccumulators()
    }
}
