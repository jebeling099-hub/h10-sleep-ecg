import Foundation

public struct AnalyzerOutput: Sendable {
    public var beats: [Beat]
    public var events: [RhythmEvent]
    public init(beats: [Beat] = [], events: [RhythmEvent] = []) {
        self.beats = beats
        self.events = events
    }
}

/// Not thread-safe. The app calls it from ONE serial queue.
public final class RealtimeAnalyzer {
    public var config: AnalyzerConfig {
        didSet {
            arrhythmiaDetector.config = config
            epochAggregator.epochDuration = config.epochSeconds
        }
    }

    private var rPeakDetector: RPeakDetector
    private var artifactDetector: ArtifactDetector
    private var beatClassifier: BeatClassifier
    private var arrhythmiaDetector: ArrhythmiaDetector
    private var hrvTracker: HRVTracker
    private var respActivity: RespirationActivityAnalyzer
    private var epochAggregator: EpochAggregator

    // ~60 s ECG ring buffer and beat history for snippet capture
    private var ecgBuffer: RingBuffer<ECGSample>
    private var beatHistory = Deque<Beat>()

    // Pending R-peaks waiting a few samples so ±100 ms QRS window is fully available
    private var pendingPeaks = Deque<DetectedRPeak>()

    // Live metrics
    private var recentNormalRRs: RingBuffer<Double>
    private var lastEcgTime: Timestamp?
    private var lastFallbackBeatTime: Timestamp?

    public init(config: AnalyzerConfig = .default) {
        self.config = config
        self.rPeakDetector = RPeakDetector(sampleRate: config.ecgSampleRate)
        self.artifactDetector = ArtifactDetector(sampleRate: config.ecgSampleRate, pauseSeconds: config.pauseSeconds)
        self.beatClassifier = BeatClassifier(sampleRate: config.ecgSampleRate)
        self.arrhythmiaDetector = ArrhythmiaDetector(config: config)
        self.hrvTracker = HRVTracker()
        self.respActivity = RespirationActivityAnalyzer(sampleRate: config.accSampleRate)
        self.epochAggregator = EpochAggregator(epochDuration: config.epochSeconds)

        let ecgBufCap = max(130, Int(ceil(65.0 * config.ecgSampleRate)))
        self.ecgBuffer = RingBuffer<ECGSample>(capacity: ecgBufCap)
        self.recentNormalRRs = RingBuffer<Double>(capacity: 5)
    }

    /// Feed ECG in arrival order (130 Hz). Returns newly detected/classified beats and
    /// newly COMPLETED events. Events carry a snippet (pre/post seconds) and are therefore
    /// emitted with a delay of about `snippetPostSeconds`.
    public func process(ecg: [ECGSample]) -> AnalyzerOutput {
        guard !ecg.isEmpty else { return AnalyzerOutput() }

        var newBeats: [Beat] = []
        var newEvents: [RhythmEvent] = []
        let halfWin = Int64(beatClassifier.halfWindowSamples)

        for sample in ecg {
            lastEcgTime = sample.t
            ecgBuffer.append(sample)

            let sampleIsArtifact = artifactDetector.processSample(sample)
            epochAggregator.recordEcgSample(at: sample.t, isArtifact: sampleIsArtifact)

            let peaks = rPeakDetector.process(sample)
            for peak in peaks {
                pendingPeaks.append(peak)
            }

            // Classify any pending peaks whose ±100 ms waveform is now complete
            while let nextPeak = pendingPeaks.first,
                  rPeakDetector.currentSampleIndex >= nextPeak.sampleIndex + halfWin {
                pendingPeaks.popFirst()
                let wave = rPeakDetector.extractWaveform(
                    centerIndex: nextPeak.sampleIndex,
                    halfWindow: beatClassifier.halfWindowSamples
                )
                let isArt = artifactDetector.evaluateBeat(
                    at: nextPeak.timestamp,
                    amplitudeUV: nextPeak.amplitudeUV,
                    rrMs: nextPeak.rrMs
                )
                let beat = beatClassifier.classify(peak: nextPeak, waveform: wave, isArtifact: isArt)
                handleClassifiedBeat(beat, hasECG: true)
                newBeats.append(beat)
            }
        }

        if let currentTime = lastEcgTime {
            // Trim beat history to last 65 s
            while let first = beatHistory.first, (currentTime - first.t) > 65.0 {
                beatHistory.popFirst()
            }

            let ready = arrhythmiaDetector.drainReadyEvents(currentTime: currentTime) { [weak self] start, end in
                self?.buildSnippet(start: start, end: end)
            }
            newEvents.append(contentsOf: ready)
        }

        return AnalyzerOutput(beats: newBeats, events: newEvents)
    }

    /// Accelerometer (25 Hz, milli-g) – used for movement, respiration, artifact detection.
    public func process(acc: [ACCSample]) {
        guard !acc.isEmpty else { return }
        for sample in acc {
            let dev = respActivity.process(sample)
            artifactDetector.updateMovement(mg: respActivity.currentMovementMG, at: sample.t)
            epochAggregator.recordActivity(dev, respirationRate: respActivity.currentRespirationRate, at: sample.t)
        }
    }

    /// RR from the standard HR service. Used only as fallback when no ECG is flowing
    /// (e.g. ECG stream not started yet). May return events (e.g. pause, brady/tachy).
    public func process(rr: [RRInterval]) -> AnalyzerOutput {
        guard !rr.isEmpty else { return AnalyzerOutput() }

        var newBeats: [Beat] = []
        var newEvents: [RhythmEvent] = []

        for interval in rr {
            // Ignore RR fallback if ECG is actively flowing
            if let ecgT = lastEcgTime, (interval.t - ecgT) < 5.0 {
                continue
            }

            let isPlausible = interval.ms >= 200.0 && interval.ms <= 15_000.0
            let cls: BeatClass = isPlausible ? .normal : .artifact
            let beat = Beat(t: interval.t, rrMs: interval.ms, amplitudeUV: 0, cls: cls)
            lastFallbackBeatTime = interval.t
            handleClassifiedBeat(beat, hasECG: false)
            newBeats.append(beat)
        }

        if let t = lastFallbackBeatTime {
            let ready = arrhythmiaDetector.drainReadyEvents(currentTime: t) { _, _ in nil }
            newEvents.append(contentsOf: ready)
        }

        return AnalyzerOutput(beats: newBeats, events: newEvents)
    }

    public var currentHeartRate: Double? {
        guard !recentNormalRRs.isEmpty else { return nil }
        var vals = recentNormalRRs.toArray()
        vals.sort()
        let median = vals[vals.count / 2]
        guard median > 1.0 else { return nil }
        return 60_000.0 / median
    }

    public var currentHRV: HRVMetrics? {
        hrvTracker.currentHRV
    }

    public var signalQuality: SignalQuality {
        artifactDetector.signalQuality
    }

    public var currentRespirationRate: Double? {
        respActivity.currentRespirationRate
    }

    /// Conditions currently active (e.g. .afibSuspected, .tachycardia) for live display.
    public var ongoingConditions: Set<RhythmEventType> {
        arrhythmiaDetector.ongoingConditions
    }

    /// Completed 30-s epochs since the last call (always produced while data flows).
    public func drainEpochs() -> [EpochSummary] {
        epochAggregator.drainEpochs()
    }

    /// Discard internal buffers (e.g. after reconnect gap > 5 s).
    public func reset() {
        rPeakDetector.reset()
        artifactDetector.reset()
        beatClassifier.reset()
        arrhythmiaDetector.reset()
        hrvTracker.reset()
        respActivity.reset()
        epochAggregator.reset()
        ecgBuffer.removeAll()
        beatHistory.removeAll()
        pendingPeaks.removeAll()
        recentNormalRRs.removeAll()
        lastEcgTime = nil
        lastFallbackBeatTime = nil
    }

    // MARK: - Internal helpers

    private func handleClassifiedBeat(_ beat: Beat, hasECG: Bool) {
        if hasECG {
            beatHistory.append(beat)
        }
        if beat.cls != .artifact, let rr = beat.rrMs, rr >= 250.0 && rr <= 2500.0 {
            recentNormalRRs.append(rr)
        }
        hrvTracker.processBeat(beat)
        epochAggregator.recordBeat(beat)
        let quality: SignalQuality = hasECG ? artifactDetector.signalQuality : .good
        arrhythmiaDetector.processBeat(beat, signalQuality: quality, hasECG: hasECG)
    }

    private func buildSnippet(start: Timestamp, end: Timestamp) -> ECGSnippet? {
        guard !ecgBuffer.isEmpty else { return nil }
        var samplesUV: [Int32] = []
        var actualStart: Timestamp?

        let n = ecgBuffer.count
        for i in 0..<n {
            let s = ecgBuffer[i]
            if s.t >= start && s.t <= end {
                if actualStart == nil { actualStart = s.t }
                samplesUV.append(s.uV)
            }
        }
        guard let snipStart = actualStart, !samplesUV.isEmpty else { return nil }

        var snippetBeats: [Beat] = []
        beatHistory.forEach { beat in
            if beat.t >= snipStart && beat.t <= end {
                snippetBeats.append(beat)
            }
        }

        return ECGSnippet(
            start: snipStart,
            sampleRate: config.ecgSampleRate,
            samplesUV: samplesUV,
            beats: snippetBeats
        )
    }
}
