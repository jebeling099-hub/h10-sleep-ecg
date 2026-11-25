import Foundation

/// Overnight sleep staging and sleep-score calculation from 30-second `EpochSummary` sequences.
public enum SleepAnalyzer {
    /// Epochs sorted by time, may contain gaps. Returns stages aligned 1:1 with `epochs`.
    public static func analyze(epochs: [EpochSummary]) -> SleepAnalysisResult {
        guard !epochs.isEmpty else {
            return SleepAnalysisResult(
                sleepOnset: nil,
                wakeTime: nil,
                totalSleepMinutes: 0,
                sleepEfficiency: 0,
                stages: [],
                awakeMinutes: 0,
                lightMinutes: 0,
                deepMinutes: 0,
                remMinutes: 0,
                restingHR: nil,
                avgRMSSD: nil,
                avgRespirationRate: nil,
                vesCount: 0,
                svesCount: 0,
                score: 0,
                scoreComponents: [
                    ScoreComponent(name: "Schlafdauer", points: 0, maxPoints: 30),
                    ScoreComponent(name: "Effizienz", points: 0, maxPoints: 20),
                    ScoreComponent(name: "Tiefschlaf", points: 0, maxPoints: 15),
                    ScoreComponent(name: "REM", points: 0, maxPoints: 15),
                    ScoreComponent(name: "Erholung", points: 0, maxPoints: 10),
                    ScoreComponent(name: "Unruhe", points: 0, maxPoints: 10)
                ]
            )
        }

        let n = epochs.count

        // 1. Night baselines from clean epochs
        let cleanHRs = epochs.compactMap { $0.artifactFraction <= 0.5 ? $0.meanHR : nil }.sorted()
        let allHRs = cleanHRs.isEmpty ? epochs.compactMap { $0.meanHR }.sorted() : cleanHRs
        let restingHR = percentile(allHRs, p: 0.10)
        let medianHR = percentile(allHRs, p: 0.50)

        let cleanRMSSDs = epochs.compactMap { $0.artifactFraction <= 0.5 ? $0.rmssd : nil }.sorted()
        let allRMSSDs = cleanRMSSDs.isEmpty ? epochs.compactMap { $0.rmssd }.sorted() : cleanRMSSDs
        let medianRMSSD = percentile(allRMSSDs, p: 0.50)

        // 2. Cole-Kripke-like sleep/wake classification using activity + HR vs night baseline
        let weights: [Double] = [0.06, 0.08, 0.12, 0.16, 0.28, 0.18, 0.12] // offsets -4...+2
        var isAwake = Array(repeating: false, count: n)

        for i in 0..<n {
            var weightedAct = 0.0
            var weightSum = 0.0
            var hasActInWindow = false

            for (wIdx, w) in weights.enumerated() {
                let idx = min(n - 1, max(0, i + wIdx - 4))
                if let act = epochs[idx].activity {
                    weightedAct += w * act
                    weightSum += w
                    hasActInWindow = true
                }
            }
            let smoothedAct = (hasActInWindow && weightSum > 0) ? (weightedAct / weightSum) : nil
            let rawAct = epochs[i].activity
            let hr = epochs[i].meanHR

            if let sAct = smoothedAct {
                let highAct = sAct > 30.0 || (rawAct ?? 0) > 45.0
                let elevatedHRWithMove: Bool
                if let h = hr, let med = medianHR {
                    elevatedHRWithMove = (h > med + 12.0 && sAct > 12.0) || (h > med + 18.0)
                } else {
                    elevatedHRWithMove = false
                }
                isAwake[i] = highAct || elevatedHRWithMove
            } else if let h = hr, let med = medianHR {
                // Fallback when accelerometer is absent (e.g. backupRR epochs)
                isAwake[i] = h > med + 10.0
            } else {
                isAwake[i] = false
            }
        }

        // Smooth isolated 1-epoch wake/sleep blips
        if n >= 3 {
            let copy = isAwake
            for i in 1..<(n - 1) {
                if copy[i - 1] == copy[i + 1] {
                    isAwake[i] = copy[i - 1]
                }
            }
        }

        // 3. Determine sleepOnset and wakeTime (first / last run of >= 3 consecutive sleep epochs)
        let firstSleepIdx = findFirstSleepRun(isAwake: isAwake, minRun: 3) ?? isAwake.firstIndex(of: false)
        let lastSleepIdx = findLastSleepRun(isAwake: isAwake, minRun: 3) ?? isAwake.lastIndex(of: false)

        let sleepOnset: Timestamp?
        let wakeTime: Timestamp?
        if let f = firstSleepIdx, let l = lastSleepIdx, f <= l {
            sleepOnset = epochs[f].start
            wakeTime = epochs[l].start + epochs[l].duration
            // Force epochs outside [f...l] to awake
            for i in 0..<f { isAwake[i] = true }
            if l + 1 < n {
                for i in (l + 1)..<n { isAwake[i] = true }
            }
        } else {
            sleepOnset = nil
            wakeTime = nil
        }

        // 4. Stage heuristics for sleep epochs (deep, REM, light)
        var stages: [SleepStage] = Array(repeating: .awake, count: n)

        for i in 0..<n {
            if isAwake[i] {
                stages[i] = .awake
                continue
            }

            let ep = epochs[i]
            let hrStd = localStdDev(epochs: epochs, center: i, radius: 2) { $0.meanHR }
            let respStd = localStdDev(epochs: epochs, center: i, radius: 2) { $0.respirationRate }
            let still = (ep.activity ?? 0) < 15.0
            let veryStill = (ep.activity ?? 0) < 12.0

            let sinceOnset = sleepOnset.map { ep.start - $0 } ?? 0.0

            // Deep sleep score: low HR, high/stable RMSSD, regular respiration, still
            var deepScore = 0
            if veryStill { deepScore += 1 }
            if let hr = ep.meanHR, let rest = restingHR, let med = medianHR {
                if hr <= rest + 4.0 || hr <= med - 2.0 { deepScore += 2 }
                else if hr <= med { deepScore += 1 }
            }
            if let rmssd = ep.rmssd, let medR = medianRMSSD {
                if rmssd >= medR * 1.05 { deepScore += 2 }
                else if rmssd >= medR * 0.90 { deepScore += 1 }
            }
            if let rStd = respStd {
                if rStd < 1.2 { deepScore += 1 }
            } else {
                // Neutral credit if respiration unavailable
                deepScore += 1
            }

            // REM sleep criteria: still, >= 60 min after onset, elevated/variable HR or irregular respiration
            let canBeREM = still && (sinceOnset >= 3600.0)
            var remScore = 0
            if canBeREM {
                if let hStd = hrStd, hStd >= 2.0 { remScore += 2 }
                if let hr = ep.meanHR, let med = medianHR, hr >= med + 1.5 { remScore += 1 }
                if let rStd = respStd, rStd >= 1.4 { remScore += 2 }
                if let rmssd = ep.rmssd, let medR = medianRMSSD, rmssd < medR * 0.95 { remScore += 1 }
            }

            if canBeREM && remScore >= 3 && deepScore < 5 {
                stages[i] = .rem
            } else if veryStill && deepScore >= 5 {
                stages[i] = .deep
            } else {
                stages[i] = .light
            }
        }

        // Smooth isolated 1-epoch sleep stage blips (never overwrite awake)
        if n >= 3 {
            let copy = stages
            for i in 1..<(n - 1) {
                if copy[i] != .awake && copy[i - 1] != .awake && copy[i - 1] == copy[i + 1] {
                    stages[i] = copy[i - 1]
                }
            }
        }

        // 5. Aggregate durations and physiological averages
        var awakeMin = 0.0
        var lightMin = 0.0
        var deepMin = 0.0
        var remMin = 0.0
        var wasoMin = 0.0
        var awakenings = 0

        var sleepRMSSDs: [Double] = []
        var sleepResps: [Double] = []
        var totalVES = 0
        var totalSVES = 0

        for i in 0..<n {
            let durMin = max(0.0, epochs[i].duration) / 60.0
            totalVES += epochs[i].vesCount
            totalSVES += epochs[i].svesCount

            switch stages[i] {
            case .awake:
                awakeMin += durMin
                if let f = firstSleepIdx, let l = lastSleepIdx, i > f && i < l {
                    wasoMin += durMin
                    if stages[i - 1] != .awake {
                        awakenings += 1
                    }
                }
            case .light:
                lightMin += durMin
            case .deep:
                deepMin += durMin
            case .rem:
                remMin += durMin
            }

            if stages[i] != .awake {
                if let r = epochs[i].rmssd { sleepRMSSDs.append(r) }
                if let resp = epochs[i].respirationRate { sleepResps.append(resp) }
            }
        }

        let totalSleepMin = lightMin + deepMin + remMin
        let totalRecordedMin = awakeMin + totalSleepMin
        let efficiency = totalRecordedMin > 0 ? min(1.0, max(0.0, totalSleepMin / totalRecordedMin)) : 0.0

        let avgRMSSD: Double? = !sleepRMSSDs.isEmpty
            ? (sleepRMSSDs.reduce(0.0, +) / Double(sleepRMSSDs.count))
            : (!allRMSSDs.isEmpty ? allRMSSDs.reduce(0.0, +) / Double(allRMSSDs.count) : nil)

        let avgResp: Double?
        if !sleepResps.isEmpty {
            avgResp = sleepResps.reduce(0.0, +) / Double(sleepResps.count)
        } else {
            let allResps = epochs.compactMap { $0.respirationRate }
            avgResp = !allResps.isEmpty ? (allResps.reduce(0.0, +) / Double(allResps.count)) : nil
        }

        // 6. Score components (total 0...100)
        let durationPts = scoreDuration(totalSleepMinutes: totalSleepMin)
        let efficiencyPts = scoreEfficiency(efficiency: efficiency)
        let deepFrac = totalSleepMin > 0 ? (deepMin / totalSleepMin) : 0.0
        let remFrac = totalSleepMin > 0 ? (remMin / totalSleepMin) : 0.0
        let deepPts = scoreStageFraction(deepFrac, optLow: 0.15, optHigh: 0.25, maxPoints: 15)
        let remPts = scoreStageFraction(remFrac, optLow: 0.20, optHigh: 0.25, maxPoints: 15)
        let recoveryPts = scoreRecovery(restingHR: restingHR, avgRMSSD: avgRMSSD)
        let sleepPeriodMin = totalSleepMin + wasoMin
        let wasoFrac = sleepPeriodMin > 0 ? (wasoMin / sleepPeriodMin) : 1.0
        let restlessnessPts = scoreRestlessness(wasoFraction: wasoFrac, awakenings: awakenings, hasSleep: totalSleepMin > 0)

        let components = [
            ScoreComponent(name: "Schlafdauer", points: durationPts, maxPoints: 30),
            ScoreComponent(name: "Effizienz", points: efficiencyPts, maxPoints: 20),
            ScoreComponent(name: "Tiefschlaf", points: deepPts, maxPoints: 15),
            ScoreComponent(name: "REM", points: remPts, maxPoints: 15),
            ScoreComponent(name: "Erholung", points: recoveryPts, maxPoints: 10),
            ScoreComponent(name: "Unruhe", points: restlessnessPts, maxPoints: 10)
        ]
        let totalScore = min(100, max(0, components.reduce(0) { $0 + $1.points }))

        return SleepAnalysisResult(
            sleepOnset: sleepOnset,
            wakeTime: wakeTime,
            totalSleepMinutes: totalSleepMin,
            sleepEfficiency: efficiency,
            stages: stages,
            awakeMinutes: awakeMin,
            lightMinutes: lightMin,
            deepMinutes: deepMin,
            remMinutes: remMin,
            restingHR: restingHR,
            avgRMSSD: avgRMSSD,
            avgRespirationRate: avgResp,
            vesCount: totalVES,
            svesCount: totalSVES,
            score: totalScore,
            scoreComponents: components
        )
    }

    // MARK: - Scoring helpers

    private static func scoreDuration(totalSleepMinutes: Double) -> Int {
        guard totalSleepMinutes > 0 else { return 0 }
        // Optimal 7–9 h (420–540 min) -> 30 pts
        if totalSleepMinutes >= 420.0 && totalSleepMinutes <= 540.0 {
            return 30
        } else if totalSleepMinutes < 420.0 {
            let ratio = max(0.0, (totalSleepMinutes - 120.0) / 300.0)
            return Int(round(ratio * 30.0))
        } else {
            let ratio = max(0.0, 1.0 - (totalSleepMinutes - 540.0) / 240.0)
            return Int(round(ratio * 30.0))
        }
    }

    private static func scoreEfficiency(efficiency: Double) -> Int {
        guard efficiency > 0 else { return 0 }
        if efficiency >= 0.90 { return 20 }
        let ratio = max(0.0, (efficiency - 0.50) / 0.40)
        return Int(round(ratio * 20.0))
    }

    private static func scoreStageFraction(_ frac: Double, optLow: Double, optHigh: Double, maxPoints: Int) -> Int {
        guard frac > 0 else { return 0 }
        if frac >= optLow && frac <= optHigh {
            return maxPoints
        } else if frac < optLow {
            let ratio = max(0.0, frac / optLow)
            return Int(round(ratio * Double(maxPoints)))
        } else {
            let ratio = max(0.0, 1.0 - (frac - optHigh) / 0.35)
            return Int(round(ratio * Double(maxPoints)))
        }
    }

    private static func scoreRecovery(restingHR: Double?, avgRMSSD: Double?) -> Int {
        if restingHR == nil && avgRMSSD == nil { return 5 }
        var scoreSum = 0.0
        var weightSum = 0.0
        if let rhr = restingHR {
            // 50 bpm -> 1.0, 85 bpm -> 0.0
            let hrNorm = min(1.0, max(0.0, (85.0 - rhr) / 35.0))
            scoreSum += hrNorm
            weightSum += 1.0
        }
        if let rmssd = avgRMSSD {
            // 15 ms -> 0.0, 60 ms -> 1.0
            let hrvNorm = min(1.0, max(0.0, (rmssd - 15.0) / 45.0))
            scoreSum += hrvNorm
            weightSum += 1.0
        }
        return Int(round((scoreSum / weightSum) * 10.0))
    }

    private static func scoreRestlessness(wasoFraction: Double, awakenings: Int, hasSleep: Bool) -> Int {
        guard hasSleep else { return 0 }
        let wasoScore = max(0.0, 1.0 - wasoFraction / 0.25) // 0% WASO -> 1.0, >= 25% -> 0.0
        let awakePenalty = min(0.5, Double(max(0, awakenings - 2)) * 0.08)
        let combined = max(0.0, wasoScore - awakePenalty)
        return Int(round(combined * 10.0))
    }

    // MARK: - Math / Window helpers

    private static func percentile(_ sorted: [Double], p: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        if sorted.count == 1 { return sorted[0] }
        let clamped = min(1.0, max(0.0, p))
        let idx = clamped * Double(sorted.count - 1)
        let low = Int(floor(idx))
        let high = min(sorted.count - 1, low + 1)
        let frac = idx - Double(low)
        return sorted[low] * (1.0 - frac) + sorted[high] * frac
    }

    private static func localStdDev(
        epochs: [EpochSummary],
        center: Int,
        radius: Int,
        extract: (EpochSummary) -> Double?
    ) -> Double? {
        let low = max(0, center - radius)
        let high = min(epochs.count - 1, center + radius)
        var vals: [Double] = []
        vals.reserveCapacity(high - low + 1)
        for i in low...high {
            if let v = extract(epochs[i]) {
                vals.append(v)
            }
        }
        guard vals.count >= 2 else { return nil }
        let mean = vals.reduce(0.0, +) / Double(vals.count)
        var sumSq = 0.0
        for v in vals {
            let d = v - mean
            sumSq += d * d
        }
        return (sumSq / Double(vals.count - 1)).squareRoot()
    }

    private static func findFirstSleepRun(isAwake: [Bool], minRun: Int) -> Int? {
        var run = 0
        for i in 0..<isAwake.count {
            if !isAwake[i] {
                run += 1
                if run >= minRun {
                    return i - minRun + 1
                }
            } else {
                run = 0
            }
        }
        return nil
    }

    private static func findLastSleepRun(isAwake: [Bool], minRun: Int) -> Int? {
        var run = 0
        for i in stride(from: isAwake.count - 1, through: 0, by: -1) {
            if !isAwake[i] {
                run += 1
                if run >= minRun {
                    return i + minRun - 1
                }
            } else {
                run = 0
            }
        }
        return nil
    }
}
