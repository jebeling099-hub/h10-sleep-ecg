import Foundation

/// Detects rhythm events from classified beats (or fallback RR intervals),
/// merges sustained patterns into single events, rate-limits snippet capture,
/// and queues events until `snippetPostSeconds` of post-event ECG has arrived.
struct ArrhythmiaDetector {
    private struct PendingEvent {
        let type: RhythmEventType
        let start: Timestamp
        let end: Timestamp
        let heartRate: Double?
        let detail: String
        let wantsSnippet: Bool
        let readyAt: Timestamp
    }

    var config: AnalyzerConfig

    private(set) var ongoingConditions: Set<RhythmEventType> = []

    // Snippet rate limiting (<= 1 snippet per 30 s per RhythmEventType)
    private var lastSnippetTime: [RhythmEventType: Timestamp] = [:]
    private let snippetCooldownSeconds: Double = 30.0
    private var pendingEvents: [PendingEvent] = []

    // Recent non-artifact beats for HR smoothing & bigeminy/trigeminy detection
    private var recentBeats: RingBuffer<Beat>
    private var recentValidRRs: RingBuffer<Double>
    private var lastBeatClass: BeatClass = .unknown

    // Held VES / VES couplet state
    private var vesRunStart: Timestamp?
    private var vesRunEnd: Timestamp?
    private var vesRunCount: Int = 0
    private var vesRunFirstRR: Double?
    private var vesRunHR: Double?

    // Bigeminy / Trigeminy pattern state
    private var bigeminyActive: Bool = false
    private var bigeminyStart: Timestamp = 0
    private var bigeminyEnd: Timestamp = 0
    private var bigeminyCycles: Int = 0

    private var trigeminyActive: Bool = false
    private var trigeminyStart: Timestamp = 0
    private var trigeminyEnd: Timestamp = 0
    private var trigeminyCycles: Int = 0

    // Bradycardia / Tachycardia state
    private var bradyStart: Timestamp?
    private var bradyLastTime: Timestamp = 0
    private var bradyMinHR: Double = 999
    private var bradyEmitted: Bool = false

    private var tachyStart: Timestamp?
    private var tachyLastTime: Timestamp = 0
    private var tachyMaxHR: Double = 0
    private var tachyEmitted: Bool = false

    // AFib suspicion state
    private var afibRRs = Deque<(t: Timestamp, rrMs: Double)>()
    private var beatsSinceAfibEval: Int = 0
    private var afibActive: Bool = false
    private var afibStart: Timestamp = 0
    private var afibEmittedForEpisode: Bool = false

    init(config: AnalyzerConfig) {
        self.config = config
        self.recentBeats = RingBuffer<Beat>(capacity: 12)
        self.recentValidRRs = RingBuffer<Double>(capacity: 5)
    }

    mutating func processBeat(_ beat: Beat, signalQuality: SignalQuality, hasECG: Bool) {
        // Never produce rhythm events from artifact beats or poor/no-contact segments
        if beat.cls == .artifact || signalQuality == .noContact || signalQuality == .poor {
            flushVesRun(hasECG: hasECG)
            endBigeminyIfActive(hasECG: hasECG)
            endTrigeminyIfActive(hasECG: hasECG)
            lastBeatClass = .artifact
            return
        }

        // 1. Pause detection (only if previous beat was not artifact and gap is plausible < 15 s)
        if let rrMs = beat.rrMs, lastBeatClass != .artifact {
            let rrSec = rrMs / 1000.0
            if rrSec > config.pauseSeconds && rrSec < 15.0 {
                let start = beat.t - rrSec
                let detail = String(format: "Pause von %.1f s", rrSec)
                queueEvent(
                    type: .pause,
                    start: start,
                    end: beat.t,
                    heartRate: smoothedHR(),
                    detail: detail,
                    hasECG: hasECG
                )
            }
        }

        // Update smoothed HR from plausible RRs
        if let rrMs = beat.rrMs, rrMs >= 250.0 && rrMs <= 2500.0 {
            recentValidRRs.append(rrMs)
        }
        let currentHR = smoothedHR()

        // 2. Bradycardia / Tachycardia
        if let hr = currentHR {
            updateRateConditions(hr: hr, t: beat.t, hasECG: hasECG)
        }

        // 3. AFib suspicion (exclude VES and beats immediately after VES/artifact)
        if let rrMs = beat.rrMs,
           (beat.cls == .normal || beat.cls == .sves),
           (lastBeatClass == .normal || lastBeatClass == .sves),
           rrMs >= 250.0 && rrMs <= 2200.0 {
            afibRRs.append((t: beat.t, rrMs: rrMs))
            while let first = afibRRs.first, (beat.t - first.t) > config.afibWindowSeconds {
                afibRRs.popFirst()
            }
            beatsSinceAfibEval += 1
            if beatsSinceAfibEval >= 5 {
                beatsSinceAfibEval = 0
                evaluateAFib(currentTime: beat.t, currentHR: currentHR, hasECG: hasECG)
            }
        }

        // 4. Ectopic patterns (only when we have beat classification from ECG)
        if hasECG {
            recentBeats.append(beat)
            updateEctopicPatterns(beat: beat, currentHR: currentHR, hasECG: hasECG)
        }

        lastBeatClass = beat.cls
    }

    /// Drain all pending events whose `readyAt <= currentTime`.
    mutating func drainReadyEvents(
        currentTime: Timestamp,
        makeSnippet: (_ start: Timestamp, _ end: Timestamp) -> ECGSnippet?
    ) -> [RhythmEvent] {
        guard !pendingEvents.isEmpty else { return [] }
        var ready: [RhythmEvent] = []
        var remaining: [PendingEvent] = []
        remaining.reserveCapacity(pendingEvents.count)

        for item in pendingEvents {
            if currentTime >= item.readyAt {
                let snippet: ECGSnippet?
                if item.wantsSnippet {
                    let snipStart = max(item.start - config.snippetPreSeconds, item.end - 20.0)
                    let snipEnd = item.end + config.snippetPostSeconds
                    snippet = makeSnippet(snipStart, snipEnd)
                } else {
                    snippet = nil
                }
                ready.append(RhythmEvent(
                    type: item.type,
                    start: item.start,
                    end: item.end,
                    heartRate: item.heartRate,
                    detail: item.detail,
                    snippet: snippet
                ))
            } else {
                remaining.append(item)
            }
        }
        pendingEvents = remaining
        return ready
    }

    // MARK: - Ectopic patterns (VES, SVES, Couplet, Bigeminy, Trigeminy)

    private mutating func updateEctopicPatterns(beat: Beat, currentHR: Double?, hasECG: Bool) {
        // Track VES couplet / run
        if beat.cls == .ves {
            if vesRunCount == 0 {
                vesRunStart = beat.t
                vesRunEnd = beat.t
                vesRunCount = 1
                vesRunFirstRR = beat.rrMs
                vesRunHR = currentHR
            } else {
                vesRunEnd = beat.t
                vesRunCount += 1
            }
        } else {
            flushVesRun(hasECG: hasECG)
        }

        // Check / maintain Bigeminy (N, E, N, E, N, E)
        let isEctopic = (beat.cls == .ves || beat.cls == .sves)
        if bigeminyActive {
            let prev = recentBeats.count >= 2 ? recentBeats[recentBeats.count - 2] : nil
            let prevEctopic = prev.map { $0.cls == .ves || $0.cls == .sves } ?? false
            if (isEctopic && !prevEctopic) || (!isEctopic && prevEctopic) {
                bigeminyEnd = beat.t
                if isEctopic { bigeminyCycles += 1 }
            } else {
                endBigeminyIfActive(hasECG: hasECG)
            }
        } else if isEctopic && matchesBigeminyStart() {
            bigeminyActive = true
            bigeminyStart = recentBeats[recentBeats.count - 6].t
            bigeminyEnd = beat.t
            bigeminyCycles = 3
            ongoingConditions.insert(.bigeminy)
            // Cancel single-VES hold since this beat is now part of bigeminy
            if vesRunCount == 1 {
                clearVesRun()
            }
        }

        // Check / maintain Trigeminy (N, N, E, N, N, E, N, N, E)
        if trigeminyActive {
            if continuesTrigeminy() {
                trigeminyEnd = beat.t
                if isEctopic { trigeminyCycles += 1 }
            } else {
                endTrigeminyIfActive(hasECG: hasECG)
            }
        } else if !bigeminyActive && isEctopic && matchesTrigeminyStart() {
            trigeminyActive = true
            trigeminyStart = recentBeats[recentBeats.count - 9].t
            trigeminyEnd = beat.t
            trigeminyCycles = 3
            ongoingConditions.insert(.trigeminy)
            if vesRunCount == 1 {
                clearVesRun()
            }
        }

        // Emit isolated SVES if not in bigeminy/trigeminy and not during active AFib
        if beat.cls == .sves && !bigeminyActive && !trigeminyActive && !afibActive {
            let hrText = currentHR.map { "\(Int(round($0))) bpm" } ?? "–"
            let rrText = beat.rrMs.map { String(format: ", Kopplungsintervall %.0f ms", $0) } ?? ""
            queueEvent(
                type: .sves,
                start: beat.t,
                end: beat.t,
                heartRate: currentHR,
                detail: "SVES bei \(hrText)\(rrText)",
                hasECG: hasECG
            )
        }
    }

    private mutating func flushVesRun(hasECG: Bool) {
        guard vesRunCount > 0, let start = vesRunStart, let end = vesRunEnd else { return }
        if vesRunCount >= 2 {
            let detail = vesRunCount == 2
                ? "VES-Couplet (2 aufeinanderfolgende VES)"
                : "VES-Salve (\(vesRunCount) aufeinanderfolgende VES)"
            queueEvent(
                type: .vesCouplet,
                start: start,
                end: end,
                heartRate: vesRunHR,
                detail: detail,
                hasECG: hasECG
            )
        } else if !bigeminyActive && !trigeminyActive {
            let hrText = vesRunHR.map { "\(Int(round($0))) bpm" } ?? "–"
            let rrText = vesRunFirstRR.map { String(format: ", Kopplungsintervall %.0f ms", $0) } ?? ""
            queueEvent(
                type: .ves,
                start: start,
                end: end,
                heartRate: vesRunHR,
                detail: "VES bei \(hrText)\(rrText)",
                hasECG: hasECG
            )
        }
        clearVesRun()
    }

    private mutating func clearVesRun() {
        vesRunStart = nil
        vesRunEnd = nil
        vesRunCount = 0
        vesRunFirstRR = nil
        vesRunHR = nil
    }

    private func matchesBigeminyStart() -> Bool {
        let n = recentBeats.count
        guard n >= 6 else { return false }
        // Pattern: N, E, N, E, N, E
        for offset in 0..<6 {
            let cls = recentBeats[n - 6 + offset].cls
            let expectEctopic = (offset % 2 == 1)
            let isEctopic = (cls == .ves || cls == .sves)
            if expectEctopic && !isEctopic { return false }
            if !expectEctopic && cls != .normal { return false }
        }
        return true
    }

    private func matchesTrigeminyStart() -> Bool {
        let n = recentBeats.count
        guard n >= 9 else { return false }
        // Pattern: N, N, E, N, N, E, N, N, E
        for offset in 0..<9 {
            let cls = recentBeats[n - 9 + offset].cls
            let expectEctopic = (offset % 3 == 2)
            let isEctopic = (cls == .ves || cls == .sves)
            if expectEctopic && !isEctopic { return false }
            if !expectEctopic && cls != .normal { return false }
        }
        return true
    }

    private func continuesTrigeminy() -> Bool {
        let n = recentBeats.count
        guard n >= 3 else { return false }
        let b0 = recentBeats[n - 3].cls
        let b1 = recentBeats[n - 2].cls
        let b2 = recentBeats[n - 1].cls
        let e0 = (b0 == .ves || b0 == .sves)
        let e1 = (b1 == .ves || b1 == .sves)
        let e2 = (b2 == .ves || b2 == .sves)
        // Valid 3-beat windows inside repeating N, N, E are: (N,N,E), (N,E,N), (E,N,N)
        let ectopicCount = (e0 ? 1 : 0) + (e1 ? 1 : 0) + (e2 ? 1 : 0)
        return ectopicCount == 1
    }

    private mutating func endBigeminyIfActive(hasECG: Bool) {
        guard bigeminyActive else { return }
        let dur = max(0, bigeminyEnd - bigeminyStart)
        let detail = String(format: "Bigeminus über %d Zyklen (%.0f s)", bigeminyCycles, dur)
        queueEvent(
            type: .bigeminy,
            start: bigeminyStart,
            end: bigeminyEnd,
            heartRate: smoothedHR(),
            detail: detail,
            hasECG: hasECG
        )
        bigeminyActive = false
        bigeminyCycles = 0
        ongoingConditions.remove(.bigeminy)
    }

    private mutating func endTrigeminyIfActive(hasECG: Bool) {
        guard trigeminyActive else { return }
        let dur = max(0, trigeminyEnd - trigeminyStart)
        let detail = String(format: "Trigeminus über %d Zyklen (%.0f s)", trigeminyCycles, dur)
        queueEvent(
            type: .trigeminy,
            start: trigeminyStart,
            end: trigeminyEnd,
            heartRate: smoothedHR(),
            detail: detail,
            hasECG: hasECG
        )
        trigeminyActive = false
        trigeminyCycles = 0
        ongoingConditions.remove(.trigeminy)
    }

    // MARK: - Bradycardia / Tachycardia

    private mutating func updateRateConditions(hr: Double, t: Timestamp, hasECG: Bool) {
        // Bradycardia
        if hr < config.bradycardiaBPM {
            if bradyStart == nil {
                bradyStart = t
                bradyMinHR = hr
                bradyEmitted = false
            } else {
                bradyMinHR = min(bradyMinHR, hr)
            }
            bradyLastTime = t
            if let start = bradyStart, (t - start) >= config.rateEventMinSeconds {
                ongoingConditions.insert(.bradycardia)
                if !bradyEmitted {
                    let dur = t - start
                    let detail = String(format: "Bradykardie: min. %.0f bpm über %.0f s", bradyMinHR, dur)
                    queueEvent(
                        type: .bradycardia,
                        start: start,
                        end: t,
                        heartRate: bradyMinHR,
                        detail: detail,
                        hasECG: hasECG
                    )
                    bradyEmitted = true
                }
            }
        } else if hr >= config.bradycardiaBPM + 2.0 {
            bradyStart = nil
            bradyMinHR = 999
            bradyEmitted = false
            ongoingConditions.remove(.bradycardia)
        }

        // Tachycardia
        if hr > config.tachycardiaBPM {
            if tachyStart == nil {
                tachyStart = t
                tachyMaxHR = hr
                tachyEmitted = false
            } else {
                tachyMaxHR = max(tachyMaxHR, hr)
            }
            tachyLastTime = t
            if let start = tachyStart, (t - start) >= config.rateEventMinSeconds {
                ongoingConditions.insert(.tachycardia)
                if !tachyEmitted {
                    let dur = t - start
                    let detail = String(format: "Tachykardie: max. %.0f bpm über %.0f s", tachyMaxHR, dur)
                    queueEvent(
                        type: .tachycardia,
                        start: start,
                        end: t,
                        heartRate: tachyMaxHR,
                        detail: detail,
                        hasECG: hasECG
                    )
                    tachyEmitted = true
                }
            }
        } else if hr <= config.tachycardiaBPM - 2.0 {
            tachyStart = nil
            tachyMaxHR = 0
            tachyEmitted = false
            ongoingConditions.remove(.tachycardia)
        }
    }

    // MARK: - AFib Suspicion

    private mutating func evaluateAFib(currentTime: Timestamp, currentHR: Double?, hasECG: Bool) {
        guard afibRRs.count >= 30, let first = afibRRs.first else { return }
        let span = currentTime - first.t
        let minSpan = min(config.afibWindowSeconds * 0.75, 90.0)
        guard span >= minSpan else { return }

        var rrs: [Double] = []
        rrs.reserveCapacity(afibRRs.count)
        afibRRs.forEach { rrs.append($0.rrMs) }

        guard let rmssd = HRVCalculator.rmssd(rrs) else { return }
        let meanRR = rrs.reduce(0.0, +) / Double(rrs.count)
        guard meanRR > 1.0 else { return }

        let nRMSSD = rmssd / meanRR
        let shannon = computeShannonEntropy(rrs)
        let tpr = computeTurningPointRatio(rrs)

        let isAFib = (nRMSSD > 0.10) && (shannon > 0.60) && (tpr >= 0.48 && tpr <= 0.88)

        if isAFib {
            if !afibActive {
                afibActive = true
                afibStart = first.t
                afibEmittedForEpisode = false
                ongoingConditions.insert(.afibSuspected)
            }
            if !afibEmittedForEpisode {
                let hrVal = currentHR ?? (60_000.0 / meanRR)
                let detail = String(
                    format: "Unregelmäßige RR-Intervalle über %.0f s (mittlere HF %.0f bpm)",
                    span, hrVal
                )
                queueEvent(
                    type: .afibSuspected,
                    start: afibStart,
                    end: currentTime,
                    heartRate: hrVal,
                    detail: detail,
                    hasECG: hasECG
                )
                afibEmittedForEpisode = true
            }
        } else if afibActive && (nRMSSD < 0.08 || shannon < 0.50) {
            afibActive = false
            afibEmittedForEpisode = false
            ongoingConditions.remove(.afibSuspected)
        }
    }

    private func computeShannonEntropy(_ rrs: [Double]) -> Double {
        guard rrs.count >= 16 else { return 0 }
        var minVal = rrs[0]
        var maxVal = rrs[0]
        for v in rrs {
            if v < minVal { minVal = v }
            if v > maxVal { maxVal = v }
        }
        let range = maxVal - minVal
        // Nearly constant RR intervals -> zero entropy
        guard range >= 100.0 else { return 0 }

        let binCount = 16
        var bins = Array(repeating: 0, count: binCount)
        for v in rrs {
            let norm = (v - minVal) / range
            let idx = min(binCount - 1, max(0, Int(norm * Double(binCount))))
            bins[idx] += 1
        }

        let n = Double(rrs.count)
        var entropy = 0.0
        for count in bins where count > 0 {
            let p = Double(count) / n
            entropy -= p * log(p)
        }
        return entropy / log(Double(binCount))
    }

    private func computeTurningPointRatio(_ rrs: [Double]) -> Double {
        guard rrs.count >= 4 else { return 0 }
        var turningPoints = 0
        for i in 1..<(rrs.count - 1) {
            let a = rrs[i - 1]
            let b = rrs[i]
            let c = rrs[i + 1]
            if (b > a && b > c) || (b < a && b < c) {
                turningPoints += 1
            }
        }
        return Double(turningPoints) / Double(rrs.count - 2)
    }

    // MARK: - Helpers

    private func smoothedHR() -> Double? {
        guard !recentValidRRs.isEmpty else { return nil }
        var vals = recentValidRRs.toArray()
        vals.sort()
        let median = vals[vals.count / 2]
        guard median > 1.0 else { return nil }
        return 60_000.0 / median
    }

    private mutating func queueEvent(
        type: RhythmEventType,
        start: Timestamp,
        end: Timestamp,
        heartRate: Double?,
        detail: String,
        hasECG: Bool
    ) {
        let wantsSnippet: Bool
        if hasECG {
            if let lastT = lastSnippetTime[type], (end - lastT) < snippetCooldownSeconds {
                wantsSnippet = false
            } else {
                lastSnippetTime[type] = end
                wantsSnippet = true
            }
        } else {
            wantsSnippet = false
        }

        let readyAt = wantsSnippet ? (end + config.snippetPostSeconds) : end
        pendingEvents.append(PendingEvent(
            type: type,
            start: start,
            end: end,
            heartRate: heartRate,
            detail: detail,
            wantsSnippet: wantsSnippet,
            readyAt: readyAt
        ))
    }

    mutating func reset() {
        ongoingConditions.removeAll()
        lastSnippetTime.removeAll()
        pendingEvents.removeAll()
        recentBeats.removeAll()
        recentValidRRs.removeAll()
        lastBeatClass = .unknown
        clearVesRun()
        bigeminyActive = false
        bigeminyCycles = 0
        trigeminyActive = false
        trigeminyCycles = 0
        bradyStart = nil
        bradyMinHR = 999
        bradyEmitted = false
        tachyStart = nil
        tachyMaxHR = 0
        tachyEmitted = false
        afibRRs.removeAll()
        beatsSinceAfibEval = 0
        afibActive = false
        afibEmittedForEpisode = false
    }
}
