import SwiftUI
import Charts
import H10Analysis

struct HRVPanelView: View {
    let hrv: HRVMetrics?
    let rrHistory: [RRInterval]

    private struct RRPoint: Identifiable {
        let id: Int
        let date: Date
        let ms: Double
    }

    private struct PoincarePoint: Identifiable {
        let id: Int
        let rrN: Double
        let rrNext: Double
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("HRV (Herzratenvariabilität)")
                    .font(.headline)
                Spacer()
                if let count = hrv?.beatCount, count > 0 {
                    Text("\(count) NN-Intervalle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            metricsGrid
            tachogramSection
            poincareSection
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var metricsGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), spacing: 10)], spacing: 10) {
            metricTile(title: "RMSSD (60 s)", value: AppFormatters.value(hrv?.rmssd60, decimals: 0, unit: "ms"))
            metricTile(title: "RMSSD (5 min)", value: AppFormatters.value(hrv?.rmssd300, decimals: 0, unit: "ms"))
            metricTile(title: "SDNN (5 min)", value: AppFormatters.value(hrv?.sdnn300, decimals: 0, unit: "ms"))
            metricTile(title: "pNN50", value: AppFormatters.value(hrv?.pnn50, decimals: 1, unit: "%"))
            metricTile(title: "Ø HF", value: AppFormatters.value(hrv?.meanHR, decimals: 0, unit: "bpm"))
        }
    }

    private func metricTile(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.headline.monospacedDigit())
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private var tachogramSection: some View {
        let points: [RRPoint] = rrHistory.enumerated().map { idx, item in
            RRPoint(id: idx, date: Date(timeIntervalSince1970: item.t), ms: item.ms)
        }

        return VStack(alignment: .leading, spacing: 6) {
            Text("RR-Tachogramm (letzte 5 min)")
                .font(.subheadline.weight(.semibold))

            if points.count < 2 {
                chartEmptyPlaceholder("Noch nicht genügend RR-Intervalle")
            } else {
                let minMS = max(250, (points.map(\.ms).min() ?? 500) - 50)
                let maxMS = min(2500, (points.map(\.ms).max() ?? 1100) + 50)
                let safeMax = max(maxMS, minMS + 100)

                Chart(points) { pt in
                    LineMark(
                        x: .value("Zeit", pt.date),
                        y: .value("RR (ms)", pt.ms)
                    )
                    .foregroundStyle(.red)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
                .chartYScale(domain: minMS...safeMax)
                .chartYAxisLabel("ms")
                .frame(height: 150)
            }
        }
    }

    private var poincareSection: some View {
        let pairs: [PoincarePoint] = {
            guard rrHistory.count >= 2 else { return [] }
            var result: [PoincarePoint] = []
            result.reserveCapacity(rrHistory.count - 1)
            for i in 0..<(rrHistory.count - 1) {
                let a = rrHistory[i]
                let b = rrHistory[i + 1]
                // Only pair consecutive beats without large gaps (> 3 s)
                if b.t - a.t <= 3.0, a.ms >= 250, a.ms <= 2200, b.ms >= 250, b.ms <= 2200 {
                    result.append(PoincarePoint(id: i, rrN: a.ms, rrNext: b.ms))
                }
            }
            return result
        }()

        return VStack(alignment: .leading, spacing: 6) {
            Text("Poincaré-Plot (RRₙ vs. RRₙ₊₁)")
                .font(.subheadline.weight(.semibold))

            if pairs.count < 3 {
                chartEmptyPlaceholder("Noch nicht genügend Schlagpaare")
            } else {
                let allVals = pairs.flatMap { [$0.rrN, $0.rrNext] }
                let lo = max(250, ((allVals.min() ?? 500) - 60).rounded(.down))
                let hi = min(2200, ((allVals.max() ?? 1100) + 60).rounded(.up))
                let safeHi = max(hi, lo + 100)

                HStack {
                    Spacer()
                    Chart {
                        LineMark(
                            x: .value("RRₙ (ms)", lo),
                            y: .value("RRₙ₊₁ (ms)", lo)
                        )
                        .foregroundStyle(Color.secondary.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

                        LineMark(
                            x: .value("RRₙ (ms)", safeHi),
                            y: .value("RRₙ₊₁ (ms)", safeHi)
                        )
                        .foregroundStyle(Color.secondary.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

                        ForEach(pairs) { pt in
                            PointMark(
                                x: .value("RRₙ (ms)", pt.rrN),
                                y: .value("RRₙ₊₁ (ms)", pt.rrNext)
                            )
                            .symbolSize(16)
                            .foregroundStyle(.red.opacity(0.65))
                        }
                    }
                    .chartXScale(domain: lo...safeHi)
                    .chartYScale(domain: lo...safeHi)
                    .chartXAxisLabel("RRₙ (ms)")
                    .chartYAxisLabel("RRₙ₊₁ (ms)")
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: 260, maxHeight: 260)
                    Spacer()
                }
            }
        }
    }

    private func chartEmptyPlaceholder(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 90)
            .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}
