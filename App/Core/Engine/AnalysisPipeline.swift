import Foundation
import H10Analysis

/// Snapshot of real-time analysis results emitted at <= 10 Hz from `AnalysisPipeline` to `AppEngine`.
struct AnalysisSnapshot: Sendable {
    let heartRate: Int?
    let hrv: HRVMetrics?
    let signalQuality: SignalQuality
    let respirationRate: Double?
    let ongoingConditions: Set<RhythmEventType>
    let newBeats: [Beat]
    let newRR: [RRInterval]
    let newEvents: [RhythmEvent]
    let drainedEpochs: [EpochSummary]
}

/// Owns the single `RealtimeAnalyzer` and serial `DispatchQueue`, keeping all DSP work
/// and mutable queue-confined state cleanly outside `@MainActor`.
final class AnalysisPipeline {
    private let queue = DispatchQueue(label: "de.jebel.h10sleep.analysis", qos: .userInitiated)
    private let ecgBuffer = ECGRingBuffer(capacity: 4500) // ~34 s at 130 Hz
    private let analyzer: RealtimeAnalyzer
    private let onSnapshot: (AnalysisSnapshot) -> Void

    // Accessed exclusively on `queue`
    private var lastDataTimestamp: Timestamp?
    private var lastECGArrivalTime: TimeInterval = 0
    private var fallbackHR: Int?
    private var pendingBeats: [Beat] = []
    private var pendingRR: [RRInterval] = []
    private var pendingEvents: [RhythmEvent] = []
    private var pendingEpochs: [EpochSummary] = []
    private var lastUIEmitTime: TimeInterval = 0
    private var isNightActive: Bool = false

    init(config: AnalyzerConfig, onSnapshot: @escaping (AnalysisSnapshot) -> Void) {
        self.analyzer = RealtimeAnalyzer(config: config)
        self.onSnapshot = onSnapshot
    }

    // MARK: - Thread-safe ECG Window

    func ecgWindow(seconds: Double) -> [ECGSample] {
        ecgBuffer.window(seconds: seconds)
    }

    func clearLiveBuffers() {
        ecgBuffer.clear()
        queue.async { [weak self] in
            self?.fallbackHR = nil
        }
    }

    // MARK: - Configuration & Night Control

    func updateConfig(_ config: AnalyzerConfig) {
        queue.async { [weak self] in
            self?.analyzer.config = config
        }
    }

    func startNight(discardPriorEpochs: Bool) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if discardPriorEpochs {
                _ = self.analyzer.drainEpochs()
                self.pendingEpochs.removeAll(keepingCapacity: true)
            }
            self.isNightActive = true
        }
    }

    func flushAndStopNight() async -> [EpochSummary] {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: [])
                    return
                }
                self.isNightActive = false
                var flushed = self.pendingEpochs
                self.pendingEpochs.removeAll(keepingCapacity: true)
                flushed.append(contentsOf: self.analyzer.drainEpochs())
                continuation.resume(returning: flushed)
            }
        }
    }

    // MARK: - Sensor Ingestion

    func enqueueECG(_ samples: [ECGSample]) {
        guard !samples.isEmpty else { return }
        ecgBuffer.append(samples)

        queue.async { [weak self] in
            guard let self = self else { return }
            self.checkForGapAndResetIfNeeded(firstTimestamp: samples[0].t)
            self.lastDataTimestamp = samples[samples.count - 1].t
            self.lastECGArrivalTime = ProcessInfo.processInfo.systemUptime

            let output = self.analyzer.process(ecg: samples)
            self.collectAnalyzerOutput(output, deriveRRFromBeats: true)
            self.emitSnapshotIfNeeded(force: !output.events.isEmpty)
        }
    }

    func enqueueACC(_ samples: [ACCSample]) {
        guard !samples.isEmpty else { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            self.analyzer.process(acc: samples)
            self.emitSnapshotIfNeeded(force: false)
        }
    }

    func enqueueHR(hr: Int, rrIntervals: [RRInterval], contact: Bool) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if hr > 0 {
                self.fallbackHR = hr
            }

            let nowUptime = ProcessInfo.processInfo.systemUptime
            let ecgIsFlowing = (nowUptime - self.lastECGArrivalTime) < 3.0

            if !ecgIsFlowing && !rrIntervals.isEmpty {
                self.checkForGapAndResetIfNeeded(firstTimestamp: rrIntervals[0].t)
                self.lastDataTimestamp = rrIntervals[rrIntervals.count - 1].t

                let output = self.analyzer.process(rr: rrIntervals)
                self.pendingRR.append(contentsOf: rrIntervals)
                self.collectAnalyzerOutput(output, deriveRRFromBeats: false)
                self.emitSnapshotIfNeeded(force: !output.events.isEmpty)
            } else {
                self.emitSnapshotIfNeeded(force: false)
            }
        }
    }

    // MARK: - Private Helpers (queue-only)

    private func checkForGapAndResetIfNeeded(firstTimestamp: Timestamp) {
        if let prev = lastDataTimestamp {
            let gap = firstTimestamp - prev
            if gap > 5.0 || gap < -5.0 {
                analyzer.reset()
            }
        }
    }

    private func collectAnalyzerOutput(_ output: AnalyzerOutput, deriveRRFromBeats: Bool) {
        if !output.beats.isEmpty {
            pendingBeats.append(contentsOf: output.beats)
            if deriveRRFromBeats {
                for beat in output.beats {
                    if beat.cls != .artifact, let rrMs = beat.rrMs, rrMs > 0 {
                        pendingRR.append(RRInterval(t: beat.t, ms: rrMs))
                    }
                }
            }
        }
        if !output.events.isEmpty {
            pendingEvents.append(contentsOf: output.events)
        }
        let epochs = analyzer.drainEpochs()
        if !epochs.isEmpty && isNightActive {
            pendingEpochs.append(contentsOf: epochs)
        }
    }

    private func emitSnapshotIfNeeded(force: Bool) {
        let nowUptime = ProcessInfo.processInfo.systemUptime
        guard force || (nowUptime - lastUIEmitTime) >= 0.1 else { return }
        lastUIEmitTime = nowUptime

        let hrValue: Int?
        if let analyzerHR = analyzer.currentHeartRate, analyzerHR.isFinite, analyzerHR > 0 {
            hrValue = Int(analyzerHR.rounded())
        } else {
            hrValue = fallbackHR
        }

        let snapshot = AnalysisSnapshot(
            heartRate: hrValue,
            hrv: analyzer.currentHRV,
            signalQuality: analyzer.signalQuality,
            respirationRate: analyzer.currentRespirationRate,
            ongoingConditions: analyzer.ongoingConditions,
            newBeats: pendingBeats,
            newRR: pendingRR,
            newEvents: pendingEvents,
            drainedEpochs: pendingEpochs
        )

        pendingBeats.removeAll(keepingCapacity: true)
        pendingRR.removeAll(keepingCapacity: true)
        pendingEvents.removeAll(keepingCapacity: true)
        pendingEpochs.removeAll(keepingCapacity: true)

        onSnapshot(snapshot)
    }
}
