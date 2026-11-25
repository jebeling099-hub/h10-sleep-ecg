import Foundation
import Observation
import SwiftData
import H10Analysis

@MainActor
@Observable
final class AppEngine {
    static let shared = AppEngine()

    let modelContainer: ModelContainer

    // MARK: - Verbindung
    private(set) var connection: ConnectionState = .idle
    private(set) var deviceName: String?
    private(set) var deviceId: String?
    private(set) var batteryLevel: Int?

    // MARK: - Live-Daten (Analyse läuft IMMER, sobald verbunden – auch im Hintergrund)
    private(set) var heartRate: Int?
    private(set) var hrv: HRVMetrics?
    private(set) var signalQuality: SignalQuality = .noContact
    private(set) var respirationRate: Double?
    private(set) var rrHistory: [RRInterval] = []
    private(set) var recentBeats: [Beat] = []
    private(set) var ongoingConditions: Set<RhythmEventType> = []
    private(set) var latestEvent: RhythmEvent?
    private(set) var todayCounts: [RhythmEventType: Int] = [:]

    // MARK: - Nacht
    private(set) var activeSession: SleepSessionRecord?
    private(set) var isFinishingSession: Bool = false

    // MARK: - Einstellungen (persisted in UserDefaults)
    var config: AnalyzerConfig {
        didSet {
            guard config != oldValue else { return }
            persistConfig(config)
            pipeline.updateConfig(config)
        }
    }

    var alertsEnabled: Bool {
        didSet {
            guard alertsEnabled != oldValue else { return }
            userDefaults.set(alertsEnabled, forKey: DefaultsKey.alertsEnabled)
            if alertsEnabled {
                alertNotifier.requestAuthorization()
            }
        }
    }

    // MARK: - Internals (not observed by SwiftUI)

    private enum DefaultsKey {
        static let deviceId = "h10.deviceId"
        static let deviceName = "h10.deviceName"
        static let analyzerConfig = "h10.analyzerConfig"
        static let alertsEnabled = "h10.alertsEnabled"
        static let activeExerciseId = "h10.activeExerciseId"
    }

    @ObservationIgnored private let userDefaults: UserDefaults = .standard
    @ObservationIgnored private let alertNotifier = AlertNotifier()
    @ObservationIgnored private var pipeline: AnalysisPipeline!
    @ObservationIgnored private var bleManager: PolarH10Manager!

    @ObservationIgnored private var sessionEpochs: [EpochSummary] = []
    @ObservationIgnored private var lastEpochPersistDate: Date = .distantPast
    @ObservationIgnored private var currentCalendarDay: Date = Calendar.current.startOfDay(for: Date())
    @ObservationIgnored private var activeExerciseId: String?

    // MARK: - Init

    private init() {
        let schema = Schema([RhythmEventRecord.self, SleepSessionRecord.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            self.modelContainer = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            let fallback = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            self.modelContainer = try! ModelContainer(for: schema, configurations: [fallback])
        }

        let loadedConfig = Self.loadConfig(from: .standard)
        self.config = loadedConfig
        self.alertsEnabled = UserDefaults.standard.bool(forKey: DefaultsKey.alertsEnabled)
        self.deviceId = UserDefaults.standard.string(forKey: DefaultsKey.deviceId)
        self.deviceName = UserDefaults.standard.string(forKey: DefaultsKey.deviceName)
        self.activeExerciseId = UserDefaults.standard.string(forKey: DefaultsKey.activeExerciseId)

        let analysisPipeline = AnalysisPipeline(config: loadedConfig) { [weak self] snapshot in
            Task { @MainActor [weak self] in
                self?.applySnapshot(snapshot)
            }
        }
        self.pipeline = analysisPipeline

        self.bleManager = PolarH10Manager(callbacks: PolarH10Callbacks(
            onConnectionStateChange: { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.handleConnectionStateChange(state)
                }
            },
            onDeviceIdentified: { [weak self] id, name in
                Task { @MainActor [weak self] in
                    self?.handleDeviceIdentified(id: id, name: name)
                }
            },
            onBatteryLevel: { [weak self] level in
                Task { @MainActor [weak self] in
                    self?.batteryLevel = level
                }
            },
            onECG: { samples in
                analysisPipeline.enqueueECG(samples)
            },
            onACC: { samples in
                analysisPipeline.enqueueACC(samples)
            },
            onHR: { hr, rrIntervals, contact in
                analysisPipeline.enqueueHR(hr: hr, rrIntervals: rrIntervals, contact: contact)
            }
        ))

        loadTodayCounts()
        restoreUnfinishedSessionIfNeeded()
        bleManager.reportInitialBluetoothState()

        if let remembered = deviceId, !remembered.isEmpty {
            bleManager.connect(rememberedDeviceId: remembered)
        }
    }

    // MARK: - Connection API

    func connect() {
        bleManager.connect(rememberedDeviceId: deviceId)
    }

    func disconnect() {
        bleManager.disconnect()
    }

    func forgetDevice() {
        bleManager.forgetDevice()
        deviceId = nil
        deviceName = nil
        batteryLevel = nil
        userDefaults.removeObject(forKey: DefaultsKey.deviceId)
        userDefaults.removeObject(forKey: DefaultsKey.deviceName)
    }

    // MARK: - Live ECG Snapshot

    /// Last `seconds` of ECG for drawing (thread-safe snapshot, cheap; UI polls at ~30 fps).
    func ecgWindow(seconds: Double) -> [ECGSample] {
        pipeline.ecgWindow(seconds: seconds)
    }

    // MARK: - Night Session API

    func startNight() {
        guard activeSession == nil, !isFinishingSession else { return }

        let now = Date()
        let session = SleepSessionRecord(startDate: now)
        let context = modelContainer.mainContext
        context.insert(session)
        try? context.save()

        activeSession = session
        sessionEpochs = []
        lastEpochPersistDate = now

        let exerciseId = "H10_\(Int(now.timeIntervalSince1970))"
        activeExerciseId = exerciseId
        userDefaults.set(exerciseId, forKey: DefaultsKey.activeExerciseId)

        pipeline.startNight(discardPriorEpochs: true)

        Task { [weak self] in
            guard let self = self else { return }
            _ = await self.bleManager.startH10RRRecording(exerciseId: exerciseId)
        }
    }

    func stopNight() async -> UUID? {
        guard let session = activeSession, !isFinishingSession else { return nil }
        isFinishingSession = true
        defer { isFinishingSession = false }

        let sessionID = session.id
        let sessionStartDate = session.startDate
        let expectedExerciseId = activeExerciseId

        let remainingEpochs = await pipeline.flushAndStopNight()
        sessionEpochs.append(contentsOf: remainingEpochs)

        // Best-effort stop & fetch H10 internal RR backup recording
        let backupRR = await bleManager.stopAndFetchH10RRRecording(
            expectedExerciseId: expectedExerciseId,
            sessionStartDate: sessionStartDate
        )

        let epochLen = config.epochSeconds
        let finalEpochs: [EpochSummary]
        let usedBackup: Bool

        if !backupRR.isEmpty {
            let backupEpochs = RRBackupAnalyzer.epochs(from: backupRR, epochSeconds: epochLen)
            let merged = RRBackupAnalyzer.merge(stream: sessionEpochs, backup: backupEpochs)
            usedBackup = merged.contains { $0.source == .backupRR }
            finalEpochs = merged
        } else {
            finalEpochs = sessionEpochs.sorted { $0.start < $1.start }
            usedBackup = finalEpochs.contains { $0.source == .backupRR }
        }

        let result = SleepAnalyzer.analyze(epochs: finalEpochs)
        let afibMinutes = computeAFibMinutes(forSessionID: sessionID)

        session.endDate = Date()
        session.epochs = finalEpochs
        session.result = result
        session.score = result.score
        session.totalSleepMinutes = result.totalSleepMinutes
        session.vesCount = result.vesCount
        session.svesCount = result.svesCount
        session.afibSuspectedMinutes = afibMinutes
        session.usedBackupRR = usedBackup

        try? modelContainer.mainContext.save()

        activeSession = nil
        sessionEpochs = []
        activeExerciseId = nil
        userDefaults.removeObject(forKey: DefaultsKey.activeExerciseId)

        return sessionID
    }

    // MARK: - MainActor State Application & Persistence

    private func applySnapshot(_ snapshot: AnalysisSnapshot) {
        resetTodayCountsIfMidnightPassed()

        heartRate = snapshot.heartRate
        hrv = snapshot.hrv
        signalQuality = snapshot.signalQuality
        respirationRate = snapshot.respirationRate
        ongoingConditions = snapshot.ongoingConditions

        let nowTimestamp = Date().timeIntervalSince1970

        if !snapshot.newBeats.isEmpty {
            recentBeats.append(contentsOf: snapshot.newBeats)
            let beatCutoff = (recentBeats.last?.t ?? nowTimestamp) - 15.0
            if let firstValid = recentBeats.firstIndex(where: { $0.t >= beatCutoff }), firstValid > 0 {
                recentBeats.removeFirst(firstValid)
            }
        }

        if !snapshot.newRR.isEmpty {
            rrHistory.append(contentsOf: snapshot.newRR)
            let rrCutoff = (rrHistory.last?.t ?? nowTimestamp) - 300.0
            if let firstValid = rrHistory.firstIndex(where: { $0.t >= rrCutoff }), firstValid > 0 {
                rrHistory.removeFirst(firstValid)
            }
        }

        if !snapshot.newEvents.isEmpty {
            let context = modelContainer.mainContext
            let currentSessionID = activeSession?.id

            for event in snapshot.newEvents {
                latestEvent = event
                todayCounts[event.type, default: 0] += 1

                let record = RhythmEventRecord(event: event, sessionID: currentSessionID)
                context.insert(record)
                alertNotifier.notifyIfNeeded(for: event, enabled: alertsEnabled)
            }
            try? context.save()
        }

        if !snapshot.drainedEpochs.isEmpty, let session = activeSession {
            sessionEpochs.append(contentsOf: snapshot.drainedEpochs)
            let now = Date()
            if now.timeIntervalSince(lastEpochPersistDate) >= 300.0 {
                session.epochs = sessionEpochs
                try? modelContainer.mainContext.save()
                lastEpochPersistDate = now
            }
        }
    }

    private func handleConnectionStateChange(_ state: ConnectionState) {
        connection = state
        if state != .connected {
            heartRate = nil
            signalQuality = .noContact
            respirationRate = nil
            ongoingConditions = []
            if state == .idle || state == .bluetoothOff || state == .unauthorized {
                batteryLevel = nil
                recentBeats = []
                pipeline.clearLiveBuffers()
            }
        }
    }

    private func handleDeviceIdentified(id: String, name: String) {
        deviceId = id
        deviceName = name
        userDefaults.set(id, forKey: DefaultsKey.deviceId)
        userDefaults.set(name, forKey: DefaultsKey.deviceName)
    }

    // MARK: - Persistence & Restoration Helpers

    private func loadTodayCounts() {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        currentCalendarDay = startOfDay

        let descriptor = FetchDescriptor<RhythmEventRecord>(
            predicate: #Predicate { $0.start >= startOfDay }
        )
        let records = (try? modelContainer.mainContext.fetch(descriptor)) ?? []
        var counts: [RhythmEventType: Int] = [:]
        for record in records {
            if let type = record.type {
                counts[type, default: 0] += 1
            }
        }
        todayCounts = counts
    }

    private func resetTodayCountsIfMidnightPassed() {
        let startOfToday = Calendar.current.startOfDay(for: Date())
        if startOfToday > currentCalendarDay {
            currentCalendarDay = startOfToday
            todayCounts = [:]
        }
    }

    private func restoreUnfinishedSessionIfNeeded() {
        let descriptor = FetchDescriptor<SleepSessionRecord>(
            predicate: #Predicate { $0.endDate == nil },
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        guard let unfinished = (try? modelContainer.mainContext.fetch(descriptor))?.first else {
            return
        }
        activeSession = unfinished
        sessionEpochs = unfinished.epochs
        lastEpochPersistDate = Date()
        pipeline.startNight(discardPriorEpochs: false)
    }

    private func computeAFibMinutes(forSessionID sessionID: UUID) -> Double {
        let targetID: UUID? = sessionID
        let descriptor = FetchDescriptor<RhythmEventRecord>(
            predicate: #Predicate { $0.sessionID == targetID }
        )
        let records = (try? modelContainer.mainContext.fetch(descriptor)) ?? []
        let intervals: [(TimeInterval, TimeInterval)] = records
            .filter { $0.type == .afibSuspected }
            .map { ($0.start.timeIntervalSince1970, max($0.start.timeIntervalSince1970, $0.end.timeIntervalSince1970)) }
            .sorted { $0.0 < $1.0 }

        guard !intervals.isEmpty else { return 0 }

        var mergedStart = intervals[0].0
        var mergedEnd = intervals[0].1
        var totalSeconds: Double = 0

        for interval in intervals.dropFirst() {
            if interval.0 <= mergedEnd {
                mergedEnd = max(mergedEnd, interval.1)
            } else {
                totalSeconds += (mergedEnd - mergedStart)
                mergedStart = interval.0
                mergedEnd = interval.1
            }
        }
        totalSeconds += (mergedEnd - mergedStart)
        return totalSeconds / 60.0
    }

    private func persistConfig(_ config: AnalyzerConfig) {
        if let data = try? JSONEncoder().encode(config) {
            userDefaults.set(data, forKey: DefaultsKey.analyzerConfig)
        }
    }

    private static func loadConfig(from defaults: UserDefaults) -> AnalyzerConfig {
        guard let data = defaults.data(forKey: DefaultsKey.analyzerConfig),
              let decoded = try? JSONDecoder().decode(AnalyzerConfig.self, from: data) else {
            return .default
        }
        return decoded
    }
}
