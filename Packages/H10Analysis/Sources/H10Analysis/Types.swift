// Shared data contract between BLE layer, analysis and UI.
// OWNER: coordinator. Do NOT change existing signatures without updating docs/ARCHITECTURE.md.
// Additive changes (new fields with default values, new helpers) are allowed.

import Foundation

/// Seconds since 1970-01-01 UTC (same as `Date().timeIntervalSince1970`).
public typealias Timestamp = Double

// MARK: - Raw input

public struct ECGSample: Sendable, Codable, Equatable {
    public var t: Timestamp
    /// Microvolts as delivered by the Polar H10 (130 Hz).
    public var uV: Int32
    public init(t: Timestamp, uV: Int32) { self.t = t; self.uV = uV }
}

public struct ACCSample: Sendable, Codable, Equatable {
    public var t: Timestamp
    /// milli-g
    public var x: Int32
    public var y: Int32
    public var z: Int32
    public init(t: Timestamp, x: Int32, y: Int32, z: Int32) { self.t = t; self.x = x; self.y = y; self.z = z }
}

public struct RRInterval: Sendable, Codable, Equatable {
    /// Time of the beat that ENDS the interval.
    public var t: Timestamp
    public var ms: Double
    public init(t: Timestamp, ms: Double) { self.t = t; self.ms = ms }
}

// MARK: - Beats & signal

public enum BeatClass: String, Sendable, Codable {
    case normal, ves, sves, artifact, unknown
}

public struct Beat: Sendable, Codable, Equatable {
    /// Time of the R peak.
    public var t: Timestamp
    /// RR interval preceding this beat in ms (nil for the first beat).
    public var rrMs: Double?
    public var amplitudeUV: Int32
    public var cls: BeatClass
    public init(t: Timestamp, rrMs: Double?, amplitudeUV: Int32, cls: BeatClass) {
        self.t = t; self.rrMs = rrMs; self.amplitudeUV = amplitudeUV; self.cls = cls
    }
}

public enum SignalQuality: String, Sendable, Codable {
    case good, fair, poor, noContact

    public var displayName: String {
        switch self {
        case .good: return "Gut"
        case .fair: return "Mittel"
        case .poor: return "Schlecht"
        case .noContact: return "Kein Hautkontakt"
        }
    }
}

// MARK: - Rhythm events

public enum RhythmEventType: String, Sendable, Codable, CaseIterable {
    case ves            // ventrikuläre Extrasystole
    case sves           // supraventrikuläre Extrasystole
    case vesCouplet     // zwei VES in Folge
    case bigeminy
    case trigeminy
    case afibSuspected  // Vorhofflimmern-Verdacht
    case bradycardia
    case tachycardia
    case pause

    public var displayName: String {
        switch self {
        case .ves: return "VES"
        case .sves: return "SVES"
        case .vesCouplet: return "VES-Couplet"
        case .bigeminy: return "Bigeminus"
        case .trigeminy: return "Trigeminus"
        case .afibSuspected: return "Vorhofflimmern-Verdacht"
        case .bradycardia: return "Bradykardie"
        case .tachycardia: return "Tachykardie"
        case .pause: return "Pause"
        }
    }

    public var explanation: String {
        switch self {
        case .ves: return "Ventrikuläre Extrasystole: verfrühter Schlag mit veränderter QRS-Form und meist kompensatorischer Pause."
        case .sves: return "Supraventrikuläre Extrasystole: verfrühter Schlag mit normaler QRS-Form."
        case .vesCouplet: return "Zwei ventrikuläre Extrasystolen direkt hintereinander."
        case .bigeminy: return "Jeder zweite Schlag ist eine Extrasystole."
        case .trigeminy: return "Jeder dritte Schlag ist eine Extrasystole."
        case .afibSuspected: return "Über mehrere Minuten stark unregelmäßige RR-Intervalle – Hinweis auf Vorhofflimmern. Keine Diagnose."
        case .bradycardia: return "Herzfrequenz unter der eingestellten Grenze."
        case .tachycardia: return "Herzfrequenz über der eingestellten Grenze."
        case .pause: return "Ungewöhnlich lange Zeit zwischen zwei Herzschlägen."
        }
    }
}

public struct ECGSnippet: Sendable, Codable, Equatable {
    public var start: Timestamp
    public var sampleRate: Double
    public var samplesUV: [Int32]
    /// Beats inside the snippet (for markers).
    public var beats: [Beat]
    public init(start: Timestamp, sampleRate: Double, samplesUV: [Int32], beats: [Beat]) {
        self.start = start; self.sampleRate = sampleRate; self.samplesUV = samplesUV; self.beats = beats
    }
}

public struct RhythmEvent: Sendable, Codable, Identifiable, Equatable {
    public var id: UUID
    public var type: RhythmEventType
    public var start: Timestamp
    public var end: Timestamp
    public var heartRate: Double?
    /// Short German description, e.g. "VES bei 62 bpm, Kopplungsintervall 480 ms".
    public var detail: String
    public var snippet: ECGSnippet?
    public init(id: UUID = UUID(), type: RhythmEventType, start: Timestamp, end: Timestamp,
                heartRate: Double?, detail: String, snippet: ECGSnippet?) {
        self.id = id; self.type = type; self.start = start; self.end = end
        self.heartRate = heartRate; self.detail = detail; self.snippet = snippet
    }
}

// MARK: - HRV

public struct HRVMetrics: Sendable, Codable, Equatable {
    public var t: Timestamp
    public var meanHR: Double?
    /// RMSSD over the last 60 s (ms), ectopic/artifact beats excluded.
    public var rmssd60: Double?
    /// RMSSD over the last 300 s (ms).
    public var rmssd300: Double?
    /// SDNN over the last 300 s (ms).
    public var sdnn300: Double?
    /// pNN50 over the last 300 s (0...100 %).
    public var pnn50: Double?
    /// Number of clean NN intervals in the 300 s window.
    public var beatCount: Int
    public init(t: Timestamp, meanHR: Double?, rmssd60: Double?, rmssd300: Double?,
                sdnn300: Double?, pnn50: Double?, beatCount: Int) {
        self.t = t; self.meanHR = meanHR; self.rmssd60 = rmssd60; self.rmssd300 = rmssd300
        self.sdnn300 = sdnn300; self.pnn50 = pnn50; self.beatCount = beatCount
    }
}

// MARK: - Sleep

public enum EpochSource: String, Sendable, Codable { case stream, backupRR }

public struct EpochSummary: Sendable, Codable, Equatable {
    public var start: Timestamp
    public var duration: Double            // seconds, normally 30
    public var meanHR: Double?
    public var minHR: Double?
    public var rmssd: Double?
    /// Movement intensity from accelerometer (arbitrary units, 0 = still). nil if no ACC.
    public var activity: Double?
    /// Breaths per minute. nil if unknown.
    public var respirationRate: Double?
    public var vesCount: Int
    public var svesCount: Int
    /// 0...1 fraction of the epoch that was noise / no contact.
    public var artifactFraction: Double
    public var source: EpochSource
    public init(start: Timestamp, duration: Double = 30, meanHR: Double?, minHR: Double?, rmssd: Double?,
                activity: Double?, respirationRate: Double?, vesCount: Int, svesCount: Int,
                artifactFraction: Double, source: EpochSource) {
        self.start = start; self.duration = duration; self.meanHR = meanHR; self.minHR = minHR
        self.rmssd = rmssd; self.activity = activity; self.respirationRate = respirationRate
        self.vesCount = vesCount; self.svesCount = svesCount
        self.artifactFraction = artifactFraction; self.source = source
    }
}

public enum SleepStage: String, Sendable, Codable, CaseIterable {
    case awake, light, deep, rem
    public var displayName: String {
        switch self {
        case .awake: return "Wach"
        case .light: return "Leicht"
        case .deep: return "Tief"
        case .rem: return "REM"
        }
    }
}

public struct ScoreComponent: Sendable, Codable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String      // German, e.g. "Schlafdauer"
    public var points: Int
    public var maxPoints: Int
    public init(name: String, points: Int, maxPoints: Int) {
        self.name = name; self.points = points; self.maxPoints = maxPoints
    }
}

public struct SleepAnalysisResult: Sendable, Codable, Equatable {
    public var sleepOnset: Timestamp?
    public var wakeTime: Timestamp?
    public var totalSleepMinutes: Double
    /// 0...1
    public var sleepEfficiency: Double
    /// One stage per input epoch (same order / count).
    public var stages: [SleepStage]
    public var awakeMinutes: Double
    public var lightMinutes: Double
    public var deepMinutes: Double
    public var remMinutes: Double
    public var restingHR: Double?
    public var avgRMSSD: Double?
    public var avgRespirationRate: Double?
    public var vesCount: Int
    public var svesCount: Int
    /// 0...100
    public var score: Int
    public var scoreComponents: [ScoreComponent]
    public init(sleepOnset: Timestamp?, wakeTime: Timestamp?, totalSleepMinutes: Double, sleepEfficiency: Double,
                stages: [SleepStage], awakeMinutes: Double, lightMinutes: Double, deepMinutes: Double,
                remMinutes: Double, restingHR: Double?, avgRMSSD: Double?, avgRespirationRate: Double?,
                vesCount: Int, svesCount: Int, score: Int, scoreComponents: [ScoreComponent]) {
        self.sleepOnset = sleepOnset; self.wakeTime = wakeTime; self.totalSleepMinutes = totalSleepMinutes
        self.sleepEfficiency = sleepEfficiency; self.stages = stages; self.awakeMinutes = awakeMinutes
        self.lightMinutes = lightMinutes; self.deepMinutes = deepMinutes; self.remMinutes = remMinutes
        self.restingHR = restingHR; self.avgRMSSD = avgRMSSD; self.avgRespirationRate = avgRespirationRate
        self.vesCount = vesCount; self.svesCount = svesCount; self.score = score; self.scoreComponents = scoreComponents
    }
}

// MARK: - Config

public struct AnalyzerConfig: Sendable, Codable, Equatable {
    public var ecgSampleRate: Double = 130
    public var accSampleRate: Double = 25
    public var bradycardiaBPM: Double = 40
    public var tachycardiaBPM: Double = 120
    /// Minimum duration a brady/tachy condition must persist before an event is emitted.
    public var rateEventMinSeconds: Double = 30
    public var pauseSeconds: Double = 2.5
    public var afibWindowSeconds: Double = 120
    public var snippetPreSeconds: Double = 5
    public var snippetPostSeconds: Double = 5
    public var epochSeconds: Double = 30
    public init() {}
    public static let `default` = AnalyzerConfig()
}
