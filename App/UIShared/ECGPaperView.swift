import SwiftUI
import H10Analysis

enum ECGGain: Double, CaseIterable, Identifiable {
    case low5 = 5.0
    case standard10 = 10.0
    case high20 = 20.0

    var id: Double { rawValue }

    var mmPerMV: Double { rawValue }

    var displayName: String {
        switch self {
        case .low5: return "5 mm/mV"
        case .standard10: return "10 mm/mV"
        case .high20: return "20 mm/mV"
        }
    }
}

/// Classic ECG paper renderer (25 mm/s, small box 1 mm = 0.04 s / 0.1 mV, big box 5 mm).
struct ECGPaperCanvas: View {
    let samples: [ECGSample]
    let beats: [Beat]
    let startTime: Timestamp
    let durationSeconds: Double
    let gain: ECGGain
    var pointsPerMM: CGFloat = 4.0

    @Environment(\.colorScheme) private var colorScheme

    /// Classic ECG paper speed: 25 mm/s.
    static let mmPerSecond: Double = 25.0

    var body: some View {
        Canvas { context, size in
            drawPaperGrid(in: &context, size: size)
            drawWaveform(in: &context, size: size)
            drawBeatMarkers(in: &context, size: size)
        }
        .background(paperBackgroundColor)
    }

    private var paperBackgroundColor: Color {
        colorScheme == .dark
            ? Color(red: 0.11, green: 0.08, blue: 0.09)
            : Color(red: 1.0, green: 0.97, blue: 0.97)
    }

    private var minorGridColor: Color {
        colorScheme == .dark
            ? Color.red.opacity(0.14)
            : Color.red.opacity(0.16)
    }

    private var majorGridColor: Color {
        colorScheme == .dark
            ? Color.red.opacity(0.32)
            : Color.red.opacity(0.38)
    }

    private var traceColor: Color {
        colorScheme == .dark
            ? Color(red: 0.95, green: 0.98, blue: 0.96)
            : Color(red: 0.08, green: 0.10, blue: 0.12)
    }

    private func drawPaperGrid(in context: inout GraphicsContext, size: CGSize) {
        let minorStep = pointsPerMM
        let majorStep = pointsPerMM * 5.0
        guard minorStep > 0 else { return }

        var minorPath = Path()
        var majorPath = Path()

        var x: CGFloat = 0
        var col = 0
        while x <= size.width + 0.5 {
            if col % 5 == 0 {
                majorPath.move(to: CGPoint(x: x, y: 0))
                majorPath.addLine(to: CGPoint(x: x, y: size.height))
            } else {
                minorPath.move(to: CGPoint(x: x, y: 0))
                minorPath.addLine(to: CGPoint(x: x, y: size.height))
            }
            x += minorStep
            col += 1
        }

        // Center major horizontal grid line on the vertical midpoint
        let midY = size.height * 0.5
        let firstRowOffset = midY.truncatingRemainder(dividingBy: majorStep)
        var y = firstRowOffset - majorStep
        while y <= size.height + majorStep {
            let distFromMid = abs(y - midY)
            let nearestMajor = (distFromMid / majorStep).rounded() * majorStep
            let isMajor = abs(distFromMid - nearestMajor) < 0.5
            if y >= 0 && y <= size.height {
                if isMajor {
                    majorPath.move(to: CGPoint(x: 0, y: y))
                    majorPath.addLine(to: CGPoint(x: size.width, y: y))
                } else {
                    minorPath.move(to: CGPoint(x: 0, y: y))
                    minorPath.addLine(to: CGPoint(x: size.width, y: y))
                }
            }
            y += minorStep
        }

        context.stroke(minorPath, with: .color(minorGridColor), lineWidth: 0.5)
        context.stroke(majorPath, with: .color(majorGridColor), lineWidth: 1.0)
    }

    private func drawWaveform(in context: inout GraphicsContext, size: CGSize) {
        guard samples.count >= 2, durationSeconds > 0 else { return }

        let baselineRemovedMV = removeDisplayBaseline(samples: samples)
        let midY = size.height * 0.55
        let pointsPerSecond = CGFloat(Self.mmPerSecond) * pointsPerMM
        let pointsPerMV = CGFloat(gain.mmPerMV) * pointsPerMM

        var path = Path()
        var penDown = false
        var lastT: Timestamp = samples[0].t

        for index in samples.indices {
            let sample = samples[index]
            let dtFromStart = sample.t - startTime
            let x = CGFloat(dtFromStart) * pointsPerSecond
            let y = midY - CGFloat(baselineRemovedMV[index]) * pointsPerMV

            // Break line on packet gaps > 0.1 s so dropouts don't draw diagonal artifacts
            if penDown && (sample.t - lastT) > 0.1 {
                penDown = false
            }

            if !penDown {
                path.move(to: CGPoint(x: x, y: y))
                penDown = true
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
            lastT = sample.t
        }

        context.stroke(
            path,
            with: .color(traceColor),
            style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)
        )
    }

    /// Lightweight O(N) moving-average baseline removal (~0.6 s window at 130 Hz) for display centering.
    private func removeDisplayBaseline(samples: [ECGSample]) -> [Double] {
        let count = samples.count
        var prefix = [Double](repeating: 0, count: count + 1)
        for i in 0..<count {
            prefix[i + 1] = prefix[i] + Double(samples[i].uV)
        }

        let halfWindow = 39 // ~78 samples ≈ 0.6 s at 130 Hz
        var result = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let lo = max(0, i - halfWindow)
            let hi = min(count - 1, i + halfWindow)
            let meanUV = (prefix[hi + 1] - prefix[lo]) / Double(hi - lo + 1)
            result[i] = (Double(samples[i].uV) - meanUV) / 1000.0
        }
        return result
    }

    private func drawBeatMarkers(in context: inout GraphicsContext, size: CGSize) {
        guard !beats.isEmpty, durationSeconds > 0 else { return }
        let endTime = startTime + durationSeconds
        let pointsPerSecond = CGFloat(Self.mmPerSecond) * pointsPerMM

        for beat in beats {
            guard beat.t >= startTime && beat.t <= endTime else { continue }

            let labelText: String
            let markerColor: Color
            switch beat.cls {
            case .ves:
                labelText = "V"
                markerColor = .orange
            case .sves:
                labelText = "S"
                markerColor = .yellow
            case .artifact:
                labelText = "A"
                markerColor = .gray
            case .normal, .unknown:
                continue
            }

            let x = CGFloat(beat.t - startTime) * pointsPerSecond

            var tick = Path()
            tick.move(to: CGPoint(x: x, y: 20))
            tick.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(
                tick,
                with: .color(markerColor.opacity(0.45)),
                style: StrokeStyle(lineWidth: 1, dash: [3, 3])
            )

            let badgeRect = CGRect(x: x - 9, y: 4, width: 18, height: 16)
            let badgePath = Path(roundedRect: badgeRect, cornerRadius: 4)
            context.fill(badgePath, with: .color(markerColor))

            let resolved = context.resolve(
                Text(labelText)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(beat.cls == .sves ? .black : .white)
            )
            context.draw(resolved, at: CGPoint(x: x, y: 12), anchor: .center)
        }
    }
}

/// Horizontal scrollable static ECG snippet view for Event Detail screens.
struct StaticECGSnippetView: View {
    let snippet: ECGSnippet
    let gain: ECGGain
    var height: CGFloat = 200
    var pointsPerMM: CGFloat = 4.0

    private var samples: [ECGSample] {
        let rate = snippet.sampleRate > 0 ? snippet.sampleRate : 130.0
        let dt = 1.0 / rate
        return snippet.samplesUV.enumerated().map { idx, uV in
            ECGSample(t: snippet.start + Double(idx) * dt, uV: uV)
        }
    }

    private var durationSeconds: Double {
        let rate = snippet.sampleRate > 0 ? snippet.sampleRate : 130.0
        return max(1.0, Double(snippet.samplesUV.count) / rate)
    }

    private var canvasWidth: CGFloat {
        max(300, CGFloat(durationSeconds * ECGPaperCanvas.mmPerSecond) * pointsPerMM)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            ECGPaperCanvas(
                samples: samples,
                beats: snippet.beats,
                startTime: snippet.start,
                durationSeconds: durationSeconds,
                gain: gain,
                pointsPerMM: pointsPerMM
            )
            .frame(width: canvasWidth, height: height)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
    }
}
