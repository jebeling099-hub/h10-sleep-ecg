import Foundation

/// Standard time-domain HRV metric calculations on clean NN intervals (in milliseconds).
public enum HRVCalculator {
    /// Root mean square of successive differences (ms). Requires at least 2 intervals.
    public static func rmssd(_ nnMs: [Double]) -> Double? {
        guard nnMs.count >= 2 else { return nil }
        var sumSq = 0.0
        for i in 1..<nnMs.count {
            let diff = nnMs[i] - nnMs[i - 1]
            sumSq += diff * diff
        }
        return (sumSq / Double(nnMs.count - 1)).squareRoot()
    }

    /// Sample standard deviation of NN intervals (ms). Requires at least 2 intervals.
    public static func sdnn(_ nnMs: [Double]) -> Double? {
        guard nnMs.count >= 2 else { return nil }
        var sum = 0.0
        for v in nnMs { sum += v }
        let mean = sum / Double(nnMs.count)
        var sumSq = 0.0
        for v in nnMs {
            let d = v - mean
            sumSq += d * d
        }
        return (sumSq / Double(nnMs.count - 1)).squareRoot()
    }

    /// Percentage of successive NN differences exceeding 50 ms (0...100 %). Requires at least 2 intervals.
    public static func pnn50(_ nnMs: [Double]) -> Double? {
        guard nnMs.count >= 2 else { return nil }
        var countOver50 = 0
        for i in 1..<nnMs.count {
            if abs(nnMs[i] - nnMs[i - 1]) > 50.0 {
                countOver50 += 1
            }
        }
        return (Double(countOver50) / Double(nnMs.count - 1)) * 100.0
    }
}

/// Streaming HRV tracker maintaining clean NN intervals over 60 s and 300 s windows.
struct HRVTracker {
    private var window300 = Deque<(t: Timestamp, nnMs: Double)>()
    private var lastBeatWasNormal: Bool = false
    private(set) var currentHRV: HRVMetrics?

    mutating func processBeat(_ beat: Beat) {
        let isNormal = (beat.cls == .normal)

        // Evict intervals older than 300 s
        while let first = window300.first, (beat.t - first.t) > 300.0 {
            window300.popFirst()
        }

        // Only include clean NN intervals (both bounding beats normal, plausible physiological range)
        if isNormal && lastBeatWasNormal, let rr = beat.rrMs, rr >= 250.0 && rr <= 2500.0 {
            window300.append((t: beat.t, nnMs: rr))
        }
        lastBeatWasNormal = isNormal

        guard !window300.isEmpty else {
            return
        }

        var nn300: [Double] = []
        nn300.reserveCapacity(window300.count)
        var nn60: [Double] = []
        let cutoff60 = beat.t - 60.0
        window300.forEach { entry in
            nn300.append(entry.nnMs)
            if entry.t >= cutoff60 {
                nn60.append(entry.nnMs)
            }
        }

        let hrSource = nn60.isEmpty ? nn300 : nn60
        let meanNN = hrSource.reduce(0.0, +) / Double(hrSource.count)
        let meanHR = meanNN > 1.0 ? (60_000.0 / meanNN) : nil

        currentHRV = HRVMetrics(
            t: beat.t,
            meanHR: meanHR,
            rmssd60: HRVCalculator.rmssd(nn60),
            rmssd300: HRVCalculator.rmssd(nn300),
            sdnn300: HRVCalculator.sdnn(nn300),
            pnn50: HRVCalculator.pnn50(nn300),
            beatCount: nn300.count
        )
    }

    mutating func reset() {
        window300.removeAll()
        lastBeatWasNormal = false
        currentHRV = nil
    }
}
