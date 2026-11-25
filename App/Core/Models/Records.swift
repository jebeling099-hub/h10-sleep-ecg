// SwiftData persistence models.
// OWNER: coordinator. Additive changes only; keep docs/ARCHITECTURE.md in sync.

import Foundation
import SwiftData
import H10Analysis

private let jsonEncoder = JSONEncoder()
private let jsonDecoder = JSONDecoder()

@Model
final class RhythmEventRecord {
    @Attribute(.unique) var id: UUID
    var typeRaw: String
    var start: Date
    var end: Date
    var heartRate: Double?
    var detail: String
    /// JSON-encoded `ECGSnippet`, stored outside the SQLite file.
    @Attribute(.externalStorage) var snippetData: Data?
    /// Set when the event happened during a night session.
    var sessionID: UUID?

    init(event: RhythmEvent, sessionID: UUID?) {
        self.id = event.id
        self.typeRaw = event.type.rawValue
        self.start = Date(timeIntervalSince1970: event.start)
        self.end = Date(timeIntervalSince1970: event.end)
        self.heartRate = event.heartRate
        self.detail = event.detail
        self.snippetData = event.snippet.flatMap { try? jsonEncoder.encode($0) }
        self.sessionID = sessionID
    }

    var type: RhythmEventType? { RhythmEventType(rawValue: typeRaw) }
    var snippet: ECGSnippet? { snippetData.flatMap { try? jsonDecoder.decode(ECGSnippet.self, from: $0) } }
}

@Model
final class SleepSessionRecord {
    @Attribute(.unique) var id: UUID
    var startDate: Date
    var endDate: Date?
    /// Cached for list display / sorting.
    var score: Int?
    var totalSleepMinutes: Double
    var vesCount: Int
    var svesCount: Int
    var afibSuspectedMinutes: Double
    var usedBackupRR: Bool
    /// JSON-encoded `SleepAnalysisResult`.
    @Attribute(.externalStorage) var resultData: Data?
    /// JSON-encoded `[EpochSummary]`.
    @Attribute(.externalStorage) var epochsData: Data?

    init(id: UUID = UUID(), startDate: Date) {
        self.id = id
        self.startDate = startDate
        self.endDate = nil
        self.score = nil
        self.totalSleepMinutes = 0
        self.vesCount = 0
        self.svesCount = 0
        self.afibSuspectedMinutes = 0
        self.usedBackupRR = false
    }

    var result: SleepAnalysisResult? {
        get { resultData.flatMap { try? jsonDecoder.decode(SleepAnalysisResult.self, from: $0) } }
        set { resultData = newValue.flatMap { try? jsonEncoder.encode($0) } }
    }

    var epochs: [EpochSummary] {
        get { epochsData.flatMap { try? jsonDecoder.decode([EpochSummary].self, from: $0) } ?? [] }
        set { epochsData = try? jsonEncoder.encode(newValue) }
    }
}
