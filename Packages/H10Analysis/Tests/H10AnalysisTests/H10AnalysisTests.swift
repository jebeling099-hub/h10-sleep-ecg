import XCTest
@testable import H10Analysis

final class H10AnalysisTests: XCTestCase {

    // MARK: - HRVCalculator

    func testHRVCalculatorHandValues() {
        // Successive diffs: +50, -50, +100, -100
        let nn = [800.0, 850.0, 800.0, 900.0, 800.0]

        let rmssd = HRVCalculator.rmssd(nn)
        XCTAssertNotNil(rmssd)
        XCTAssertEqual(rmssd!, 6250.0.squareRoot(), accuracy: 1e-6)

        let sdnn = HRVCalculator.sdnn(nn)
        XCTAssertNotNil(sdnn)
        XCTAssertEqual(sdnn!, 2000.0.squareRoot(), accuracy: 1e-6)

        let pnn50 = HRVCalculator.pnn50(nn)
        XCTAssertNotNil(pnn50)
        XCTAssertEqual(pnn50!, 50.0, accuracy: 1e-6)
    }

    func testHRVCalculatorEdgeCases() {
        XCTAssertNil(HRVCalculator.rmssd([]))
        XCTAssertNil(HRVCalculator.rmssd([800.0]))
        XCTAssertNil(HRVCalculator.sdnn([]))
        XCTAssertNil(HRVCalculator.sdnn([800.0]))
        XCTAssertNil(HRVCalculator.pnn50([]))
        XCTAssertNil(HRVCalculator.pnn50([800.0]))
    }

    // MARK: - R-Peak Detection Sensitivity & PPV

    func testRPeakDetectionSensitivityAndPPVPositivePolarity() {
        assertRPeakAccuracy(polarity: 1.0)
    }

    func testRPeakDetectionSensitivityAndPPVNegativePolarity() {
        assertRPeakAccuracy(polarity: -1.0)
    }

    private func assertRPeakAccuracy(polarity: Double) {
        let startTime: Timestamp = 1_700_000_000.0
        var specs: [SyntheticBeatSpec] = []
        var t = 1.0
        // 60 seconds at ~75 bpm (0.8 s RR) -> 73 beats
        while t < 59.0 {
            specs.append(SyntheticBeatSpec(time: t, kind: .normal))
            t += 0.8
        }

        let samples = SyntheticECG.generate(
            beats: specs,
            durationSeconds: 60.0,
            sampleRate: 130.0,
            startTime: startTime,
            polarity: polarity
        )

        let analyzer = RealtimeAnalyzer()
        var detectedBeats: [Beat] = []
        // Feed in realistic ~1 s chunks
        let chunkSize = 130
        var idx = 0
        while idx < samples.count {
            let end = min(samples.count, idx + chunkSize)
            let out = analyzer.process(ecg: Array(samples[idx..<end]))
            detectedBeats.append(contentsOf: out.beats)
            idx = end
        }

        // Match detected beats to true beat timestamps within ±50 ms
        let tolerance = 0.050
        var truePositives = 0
        var usedDetected = Set<Int>()
        for spec in specs {
            let expectedT = startTime + spec.time
            if let matchIdx = detectedBeats.indices.first(where: { i in
                !usedDetected.contains(i) && abs(detectedBeats[i].t - expectedT) <= tolerance
            }) {
                truePositives += 1
                usedDetected.insert(matchIdx)
            }
        }

        let sensitivity = Double(truePositives) / Double(specs.count)
        let ppv = detectedBeats.isEmpty ? 0.0 : Double(truePositives) / Double(detectedBeats.count)

        XCTAssertGreaterThan(sensitivity, 0.98, "Sensitivity too low: \(sensitivity)")
        XCTAssertGreaterThan(ppv, 0.98, "PPV too low: \(ppv)")
        XCTAssertEqual(analyzer.signalQuality, .good)
        XCTAssertNotNil(analyzer.currentHeartRate)
        if let hr = analyzer.currentHeartRate {
            XCTAssertEqual(hr, 75.0, accuracy: 2.0)
        }
        XCTAssertNotNil(analyzer.currentHRV)
    }

    // MARK: - Beat Classification: VES & SVES

    func testPrematureWideBeatClassifiedAsVES() {
        let startTime: Timestamp = 1_700_000_000.0
        var specs: [SyntheticBeatSpec] = []
        var t = 1.0
        // 15 normal beats (learning + stable template)
        for _ in 0..<15 {
            specs.append(SyntheticBeatSpec(time: t, kind: .normal))
            t += 0.8
        }
        // Premature wide VES (coupling interval 0.50 s) + compensatory pause (1.10 s)
        let vesTime = t - 0.30
        specs.append(SyntheticBeatSpec(time: vesTime, kind: .ves))
        t = vesTime + 1.10
        // 12 more normal beats so post-snippet window completes
        for _ in 0..<12 {
            specs.append(SyntheticBeatSpec(time: t, kind: .normal))
            t += 0.8
        }

        let samples = SyntheticECG.generate(
            beats: specs,
            durationSeconds: t + 1.0,
            sampleRate: 130.0,
            startTime: startTime
        )

        let analyzer = RealtimeAnalyzer()
        let output = analyzer.process(ecg: samples)

        let vesBeats = output.beats.filter { $0.cls == .ves }
        XCTAssertGreaterThanOrEqual(vesBeats.count, 1, "Expected at least one VES beat")

        let vesEvents = output.events.filter { $0.type == .ves }
        XCTAssertGreaterThanOrEqual(vesEvents.count, 1, "Expected a VES rhythm event")
        XCTAssertNotNil(vesEvents.first?.snippet, "Expected ECG snippet attached to VES event")
    }

    func testPrematureNormalBeatClassifiedAsSVES() {
        let startTime: Timestamp = 1_700_000_000.0
        var specs: [SyntheticBeatSpec] = []
        var t = 1.0
        for _ in 0..<15 {
            specs.append(SyntheticBeatSpec(time: t, kind: .normal))
            t += 0.8
        }
        // Premature narrow SVES (coupling interval 0.55 s)
        let svesTime = t - 0.25
        specs.append(SyntheticBeatSpec(time: svesTime, kind: .sves))
        t = svesTime + 0.90
        for _ in 0..<12 {
            specs.append(SyntheticBeatSpec(time: t, kind: .normal))
            t += 0.8
        }

        let samples = SyntheticECG.generate(
            beats: specs,
            durationSeconds: t + 1.0,
            sampleRate: 130.0,
            startTime: startTime
        )

        let analyzer = RealtimeAnalyzer()
        let output = analyzer.process(ecg: samples)

        let svesBeats = output.beats.filter { $0.cls == .sves }
        XCTAssertGreaterThanOrEqual(svesBeats.count, 1, "Expected at least one SVES beat")

        let svesEvents = output.events.filter { $0.type == .sves }
        XCTAssertGreaterThanOrEqual(svesEvents.count, 1, "Expected an SVES rhythm event")
    }

    // MARK: - Pause Detection

    func testPauseDetection() {
        let startTime: Timestamp = 1_700_000_000.0
        var specs: [SyntheticBeatSpec] = []
        var t = 1.0
        for _ in 0..<12 {
            specs.append(SyntheticBeatSpec(time: t, kind: .normal))
            t += 0.8
        }
        // Insert a 3.2 s pause (> default 2.5 s)
        t += 2.4 // total gap from last beat = 0.8 + 2.4 = 3.2 s
        for _ in 0..<12 {
            specs.append(SyntheticBeatSpec(time: t, kind: .normal))
            t += 0.8
        }

        let samples = SyntheticECG.generate(
            beats: specs,
            durationSeconds: t + 1.0,
            sampleRate: 130.0,
            startTime: startTime
        )

        let analyzer = RealtimeAnalyzer()
        let output = analyzer.process(ecg: samples)

        let pauseEvents = output.events.filter { $0.type == .pause }
        XCTAssertEqual(pauseEvents.count, 1, "Expected exactly one pause event")
        XCTAssertNotNil(pauseEvents.first?.snippet)
    }

    // MARK: - AFib Suspicion vs Regular Rhythm

    func testIrregularRRTriggersAFibSuspected() {
        let startTime: Timestamp = 1_700_000_000.0
        var rng = SeededRNG(seed: 42)
        var specs: [SyntheticBeatSpec] = []
        var t = 1.0
        // 150 seconds of strongly irregular RR intervals (0.45 s ... 1.15 s)
        while t < 155.0 {
            specs.append(SyntheticBeatSpec(time: t, kind: .normal))
            t += rng.nextDouble(in: 0.45...1.15)
        }

        let samples = SyntheticECG.generate(
            beats: specs,
            durationSeconds: t + 6.0,
            sampleRate: 130.0,
            startTime: startTime
        )

        let analyzer = RealtimeAnalyzer()
        let output = analyzer.process(ecg: samples)

        let afibEvents = output.events.filter { $0.type == .afibSuspected }
        XCTAssertGreaterThanOrEqual(afibEvents.count, 1, "Expected afibSuspected event for irregular RR")
        XCTAssertTrue(analyzer.ongoingConditions.contains(.afibSuspected))
    }

    func testRegularRRYieldsNoAFibSuspected() {
        let startTime: Timestamp = 1_700_000_000.0
        var specs: [SyntheticBeatSpec] = []
        var t = 1.0
        var idx = 0
        // 150 seconds of regular sinus rhythm with mild respiratory sinus arrhythmia (±15 ms)
        while t < 155.0 {
            specs.append(SyntheticBeatSpec(time: t, kind: .normal))
            let rsa = 0.015 * sin(Double(idx) * 0.5)
            t += 0.85 + rsa
            idx += 1
        }

        let samples = SyntheticECG.generate(
            beats: specs,
            durationSeconds: t + 6.0,
            sampleRate: 130.0,
            startTime: startTime
        )

        let analyzer = RealtimeAnalyzer()
        let output = analyzer.process(ecg: samples)

        let afibEvents = output.events.filter { $0.type == .afibSuspected }
        XCTAssertTrue(afibEvents.isEmpty, "Regular sinus rhythm must not trigger afibSuspected")
        XCTAssertFalse(analyzer.ongoingConditions.contains(.afibSuspected))
    }

    // MARK: - ACC Respiration & Epochs

    func testRespirationEstimationAndEpochs() {
        let analyzer = RealtimeAnalyzer()
        let startTime: Timestamp = 1_700_000_000.0
        let fs = 25.0
        // 65 seconds of still chest ACC with 15 breaths/min (0.25 Hz) on Z axis
        var acc: [ACCSample] = []
        let total = Int(65.0 * fs)
        acc.reserveCapacity(total)
        for i in 0..<total {
            let t = Double(i) / fs
            let breath = 15.0 * sin(2.0 * Double.pi * 0.25 * t)
            acc.append(ACCSample(t: startTime + t, x: 0, y: 0, z: Int32(round(1000.0 + breath))))
        }

        analyzer.process(acc: acc)
        XCTAssertNotNil(analyzer.currentRespirationRate)
        if let resp = analyzer.currentRespirationRate {
            XCTAssertEqual(resp, 15.0, accuracy: 2.5)
        }

        let epochs = analyzer.drainEpochs()
        XCTAssertGreaterThanOrEqual(epochs.count, 2)
        XCTAssertTrue(analyzer.drainEpochs().isEmpty)
    }

    // MARK: - RR Fallback & RRBackupAnalyzer

    func testRRBackupEpochsAndMerge() {
        let startTime: Timestamp = 1_700_000_000.0
        var rrs: [RRInterval] = []
        var t = startTime
        for _ in 0..<120 {
            t += 0.8
            rrs.append(RRInterval(t: t, ms: 800.0))
        }

        let backup = RRBackupAnalyzer.epochs(from: rrs, epochSeconds: 30)
        XCTAssertGreaterThanOrEqual(backup.count, 3)
        XCTAssertTrue(backup.allSatisfy { $0.source == .backupRR })

        // Stream covers first epoch only; backup should fill the rest
        let streamEpoch = EpochSummary(
            start: backup[0].start,
            duration: 30,
            meanHR: 72,
            minHR: 70,
            rmssd: 45,
            activity: 3,
            respirationRate: 14,
            vesCount: 0,
            svesCount: 0,
            artifactFraction: 0,
            source: .stream
        )
        let merged = RRBackupAnalyzer.merge(stream: [streamEpoch], backup: backup)
        XCTAssertEqual(merged.count, backup.count)
        XCTAssertEqual(merged[0].source, .stream)
        XCTAssertEqual(merged[1].source, .backupRR)
    }

    // MARK: - SleepAnalyzer

    func testSleepAnalyzerSyntheticNight() {
        let startTime: Timestamp = 1_700_000_000.0
        var epochs: [EpochSummary] = []
        // 8 hours = 960 epochs of 30 s
        // 0..29 (15 min): awake
        // 30..929 (7.5 h): cycles of light, deep, REM
        // 930..959 (15 min): awake
        for i in 0..<960 {
            let t = startTime + Double(i) * 30.0
            let meanHR: Double
            let rmssd: Double
            let activity: Double
            let resp: Double

            if i < 30 || i >= 930 {
                // Awake
                meanHR = 76.0
                rmssd = 25.0
                activity = 65.0
                resp = 16.0
            } else {
                let sleepIdx = i - 30
                let cyclePos = sleepIdx % 180 // 90-min cycle = 180 epochs
                if cyclePos < 50 {
                    // Deep sleep (low HR, high RMSSD, regular resp, still)
                    meanHR = 52.0
                    rmssd = 68.0
                    activity = 2.0
                    resp = 12.5
                } else if cyclePos >= 130 && sleepIdx >= 120 {
                    // REM (> 60 min after onset, variable HR, irregular resp, still)
                    let swing = (i % 2 == 0) ? 4.5 : -4.5
                    meanHR = 63.0 + swing
                    rmssd = 32.0
                    activity = 4.0
                    resp = 15.0 + ((i % 2 == 0) ? 2.5 : -2.5)
                } else {
                    // Light sleep
                    meanHR = 59.0
                    rmssd = 46.0
                    activity = 6.0
                    resp = 14.0
                }
            }

            epochs.append(EpochSummary(
                start: t,
                duration: 30,
                meanHR: meanHR,
                minHR: meanHR - 2.0,
                rmssd: rmssd,
                activity: activity,
                respirationRate: resp,
                vesCount: 0,
                svesCount: 0,
                artifactFraction: 0,
                source: .stream
            ))
        }

        let result = SleepAnalyzer.analyze(epochs: epochs)
        XCTAssertEqual(result.stages.count, epochs.count)
        XCTAssertNotNil(result.sleepOnset)
        XCTAssertNotNil(result.wakeTime)
        XCTAssertGreaterThan(result.totalSleepMinutes, 360.0)
        XCTAssertGreaterThan(result.deepMinutes, 30.0)
        XCTAssertGreaterThan(result.remMinutes, 30.0)
        XCTAssertGreaterThanOrEqual(result.score, 60)
        XCTAssertLessThanOrEqual(result.score, 100)

        let expectedNames = ["Schlafdauer", "Effizienz", "Tiefschlaf", "REM", "Erholung", "Unruhe"]
        let expectedMax = [30, 20, 15, 15, 10, 10]
        XCTAssertEqual(result.scoreComponents.map { $0.name }, expectedNames)
        XCTAssertEqual(result.scoreComponents.map { $0.maxPoints }, expectedMax)
    }

    func testEmptyInputsDoNotCrash() {
        let analyzer = RealtimeAnalyzer()
        let ecgOut = analyzer.process(ecg: [])
        XCTAssertTrue(ecgOut.beats.isEmpty)
        XCTAssertTrue(ecgOut.events.isEmpty)

        analyzer.process(acc: [])
        let rrOut = analyzer.process(rr: [])
        XCTAssertTrue(rrOut.beats.isEmpty)
        XCTAssertTrue(rrOut.events.isEmpty)
        XCTAssertTrue(analyzer.drainEpochs().isEmpty)
        analyzer.reset()

        let emptySleep = SleepAnalyzer.analyze(epochs: [])
        XCTAssertEqual(emptySleep.score, 0)
        XCTAssertTrue(emptySleep.stages.isEmpty)
        XCTAssertNil(emptySleep.sleepOnset)
        XCTAssertEqual(emptySleep.scoreComponents.count, 6)

        XCTAssertTrue(RRBackupAnalyzer.epochs(from: []).isEmpty)
        XCTAssertTrue(RRBackupAnalyzer.merge(stream: [], backup: []).isEmpty)
    }
}
