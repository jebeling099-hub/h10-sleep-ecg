import Foundation

/// Converts H10 internal RR backup recordings into epochs and merges them with live stream epochs.
public enum RRBackupAnalyzer {
    /// Build epochs from the H10 internal RR recording (used to fill gaps of the stream).
    public static func epochs(from rr: [RRInterval], epochSeconds: Double = 30) -> [EpochSummary] {
        guard !rr.isEmpty, epochSeconds > 0 else { return [] }
        let sorted = rr.sorted { $0.t < $1.t }
        let baseTime = sorted[0].t

        var result: [EpochSummary] = []
        var currentBucket = 0
        var cleanRRs: [Double] = []
        var totalCount = 0
        var badCount = 0

        func flushBucket(_ bucket: Int) {
            guard totalCount > 0 else { return }
            let start = baseTime + Double(bucket) * epochSeconds
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

            let artifactFraction = Double(badCount) / Double(totalCount)
            result.append(EpochSummary(
                start: start,
                duration: epochSeconds,
                meanHR: meanHR,
                minHR: minHR,
                rmssd: rmssd,
                activity: nil,
                respirationRate: nil,
                vesCount: 0,
                svesCount: 0,
                artifactFraction: min(1.0, max(0.0, artifactFraction)),
                source: .backupRR
            ))
        }

        for interval in sorted {
            let bucket = max(0, Int(floor((interval.t - baseTime) / epochSeconds)))
            if bucket != currentBucket {
                flushBucket(currentBucket)
                cleanRRs.removeAll(keepingCapacity: true)
                totalCount = 0
                badCount = 0
                currentBucket = bucket
            }
            totalCount += 1
            if interval.ms >= 250.0 && interval.ms <= 2500.0 {
                cleanRRs.append(interval.ms)
            } else {
                badCount += 1
            }
        }
        flushBucket(currentBucket)

        return result
    }

    /// Merge: stream epochs win; backup epochs fill time ranges without stream epochs.
    public static func merge(stream: [EpochSummary], backup: [EpochSummary]) -> [EpochSummary] {
        let sortedStream = stream.sorted { $0.start < $1.start }
        guard !backup.isEmpty else { return sortedStream }
        guard !sortedStream.isEmpty else { return backup.sorted { $0.start < $1.start } }

        var merged = sortedStream
        merged.reserveCapacity(sortedStream.count + backup.count)

        let overlapTolerance = 1.0
        for b in backup {
            let bStart = b.start
            let bEnd = b.start + b.duration
            let overlapsStream = sortedStream.contains { s in
                let sStart = s.start
                let sEnd = s.start + s.duration
                let overlap = min(bEnd, sEnd) - max(bStart, sStart)
                return overlap > overlapTolerance
            }
            if !overlapsStream {
                merged.append(b)
            }
        }

        merged.sort { $0.start < $1.start }
        return merged
    }
}
