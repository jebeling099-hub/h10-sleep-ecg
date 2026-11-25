import SwiftUI
import SwiftData
import Charts
import H10Analysis

struct SleepReportView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let record: SleepSessionRecord

    @State private var decodedResult: SleepAnalysisResult?
    @State private var decodedEpochs: [EpochSummary] = []
    @State private var didLoad = false
    @State private var showDeleteConfirmation = false

    private struct HypnoPoint: Identifiable {
        let id: Int
        let date: Date
        let level: Int
        let stage: SleepStage
    }

    private struct EpochMetricPoint: Identifiable {
        let id: Int
        let date: Date
        let value: Double
    }

    private struct StageRow: Identifiable {
        var id: SleepStage { stage }
        let stage: SleepStage
        let minutes: Double
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let result = decodedResult {
                    scoreCard(result: result)
                    overviewStatsCard(result: result)
                    stagesCard(result: result)
                    hypnogramCard(result: result)
                    overnightCurvesCard
                    rhythmSummaryCard(result: result)
                } else if didLoad {
                    ContentUnavailableView(
                        "Keine Auswertung",
                        systemImage: "moon.zzz",
                        description: Text("Für diese Nacht liegen keine ausreichenden Schlafdaten vor.")
                    )
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 120)
                }

                NightEventsSection(sessionID: record.id)

                Text(DisclaimerCopy.shortNotice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(AppFormatters.nightRowDate(record.startDate))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .destructiveAction) {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("Löschen", systemImage: "trash")
                }
            }
        }
        .alert("Nacht löschen?", isPresented: $showDeleteConfirmation) {
            Button("Abbrechen", role: .cancel) {}
            Button("Löschen", role: .destructive) {
                modelContext.delete(record)
                dismiss()
            }
        } message: {
            Text("Dieser Schlafbericht wird dauerhaft gelöscht.")
        }
        .onAppear {
            if !didLoad {
                decodedResult = record.result
                decodedEpochs = record.epochs
                didLoad = true
            }
        }
    }

    // MARK: - Score Ring & Components

    private func scoreCard(result: SleepAnalysisResult) -> some View {
        let score = max(0, min(100, result.score))
        let color = UIStyle.scoreColor(for: score)

        return VStack(spacing: 16) {
            HStack(spacing: 20) {
                ZStack {
                    Circle()
                        .stroke(color.opacity(0.2), lineWidth: 14)
                    Circle()
                        .trim(from: 0, to: CGFloat(score) / 100.0)
                        .stroke(color, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 2) {
                        Text("\(score)")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text("Schlaf-Score")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 116, height: 116)

                VStack(alignment: .leading, spacing: 8) {
                    Text(AppFormatters.duration(minutes: result.totalSleepMinutes))
                        .font(.title2.bold())
                    Text("Effizienz: \(AppFormatters.percent(result.sleepEfficiency))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if record.usedBackupRR {
                        Label("Backup-RR ergänzt", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .foregroundStyle(.indigo)
                    }
                }

                Spacer()
            }

            if !result.scoreComponents.isEmpty {
                Divider()
                VStack(spacing: 10) {
                    ForEach(result.scoreComponents) { component in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(component.name)
                                    .font(.caption.weight(.medium))
                                Spacer()
                                Text("\(component.points) / \(component.maxPoints)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            ProgressView(
                                value: Double(max(0, component.points)),
                                total: Double(max(1, component.maxPoints))
                            )
                            .tint(color)
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Overview Stats

    private func overviewStatsCard(result: SleepAnalysisResult) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), spacing: 10)], spacing: 10) {
            statTile(title: "Eingeschlafen", value: AppFormatters.time(timestamp: result.sleepOnset), icon: "moon.fill", color: .indigo)
            statTile(title: "Aufgewacht", value: AppFormatters.time(timestamp: result.wakeTime), icon: "sun.max.fill", color: .orange)
            statTile(title: "Ruhepuls", value: AppFormatters.value(result.restingHR, decimals: 0, unit: "bpm"), icon: "heart.fill", color: .red)
            statTile(title: "Ø RMSSD", value: AppFormatters.value(result.avgRMSSD, decimals: 0, unit: "ms"), icon: "waveform.path.ecg", color: .green)
            statTile(title: "Ø Atmung", value: AppFormatters.value(result.avgRespirationRate, decimals: 1, unit: "/min"), icon: "lungs.fill", color: .teal)
        }
    }

    private func statTile(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(color)
            Text(value)
                .font(.headline.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Stages Breakdown

    private func stagesCard(result: SleepAnalysisResult) -> some View {
        let totalTracked = max(1.0, result.awakeMinutes + result.lightMinutes + result.deepMinutes + result.remMinutes)
        let rows: [StageRow] = [
            StageRow(stage: .deep, minutes: result.deepMinutes),
            StageRow(stage: .rem, minutes: result.remMinutes),
            StageRow(stage: .light, minutes: result.lightMinutes),
            StageRow(stage: .awake, minutes: result.awakeMinutes)
        ]

        return VStack(alignment: .leading, spacing: 12) {
            Text("Schlafphasen")
                .font(.headline)

            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(rows) { item in
                        let fraction = max(0, item.minutes / totalTracked)
                        if fraction > 0 {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(item.stage.color)
                                .frame(width: max(4, geo.size.width * fraction))
                        }
                    }
                }
            }
            .frame(height: 14)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(rows) { item in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(item.stage.color)
                            .frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.stage.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(AppFormatters.duration(minutes: item.minutes))
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                        }
                        Spacer()
                    }
                    .padding(8)
                    .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Hypnogram

    private func hypnogramCard(result: SleepAnalysisResult) -> some View {
        let count = min(decodedEpochs.count, result.stages.count)
        let points: [HypnoPoint] = (0..<count).map { idx in
            let stage = result.stages[idx]
            return HypnoPoint(
                id: idx,
                date: Date(timeIntervalSince1970: decodedEpochs[idx].start),
                level: stage.chartLevel,
                stage: stage
            )
        }

        return VStack(alignment: .leading, spacing: 10) {
            Text("Hypnogramm")
                .font(.headline)

            if points.count < 2 {
                Text("Nicht genügend Epochen für ein Hypnogramm.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Chart(points) { pt in
                    LineMark(
                        x: .value("Zeit", pt.date),
                        y: .value("Phase", pt.level)
                    )
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(.indigo)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
                .chartYScale(domain: 0...3)
                .chartYAxis {
                    AxisMarks(values: [0, 1, 2, 3]) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let intVal = value.as(Int.self) {
                                Text(SleepStage.fromChartLevel(intVal).displayName)
                                    .font(.caption2)
                            }
                        }
                    }
                }
                .frame(height: 170)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Overnight Curves

    private var overnightCurvesCard: some View {
        let hrPoints: [EpochMetricPoint] = decodedEpochs.enumerated().compactMap { idx, ep in
            guard let v = ep.meanHR, v.isFinite else { return nil }
            return EpochMetricPoint(id: idx, date: Date(timeIntervalSince1970: ep.start), value: v)
        }
        let rmssdPoints: [EpochMetricPoint] = decodedEpochs.enumerated().compactMap { idx, ep in
            guard let v = ep.rmssd, v.isFinite else { return nil }
            return EpochMetricPoint(id: idx, date: Date(timeIntervalSince1970: ep.start), value: v)
        }
        let respPoints: [EpochMetricPoint] = decodedEpochs.enumerated().compactMap { idx, ep in
            guard let v = ep.respirationRate, v.isFinite else { return nil }
            return EpochMetricPoint(id: idx, date: Date(timeIntervalSince1970: ep.start), value: v)
        }

        return VStack(alignment: .leading, spacing: 18) {
            Text("Verlauf über die Nacht")
                .font(.headline)

            metricChart(title: "Herzfrequenz (bpm)", unit: "bpm", color: .red, points: hrPoints)
            metricChart(title: "HRV / RMSSD (ms)", unit: "ms", color: .green, points: rmssdPoints)
            metricChart(title: "Atemfrequenz (/min)", unit: "/min", color: .teal, points: respPoints)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func metricChart(title: String, unit: String, color: Color, points: [EpochMetricPoint]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            if points.count < 2 {
                Text("Keine Verlaufsdaten verfügbar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 70)
                    .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
            } else {
                Chart(points) { pt in
                    LineMark(
                        x: .value("Zeit", pt.date),
                        y: .value(unit, pt.value)
                    )
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.8))
                }
                .chartYAxisLabel(unit)
                .frame(height: 120)
            }
        }
    }

    // MARK: - Rhythm Summary

    private func rhythmSummaryCard(result: SleepAnalysisResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Herzrhythmus in dieser Nacht")
                .font(.headline)

            HStack(spacing: 12) {
                rhythmCountPill(title: "VES", count: result.vesCount, color: .orange)
                rhythmCountPill(title: "SVES", count: result.svesCount, color: .yellow)
                if record.afibSuspectedMinutes > 0 {
                    rhythmCountPill(
                        title: "AF-Verdacht",
                        valueText: AppFormatters.duration(minutes: record.afibSuspectedMinutes),
                        color: .red
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func rhythmCountPill(title: String, count: Int, color: Color) -> some View {
        rhythmCountPill(title: title, valueText: "\(count)", color: color)
    }

    private func rhythmCountPill(title: String, valueText: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(valueText)
                .font(.headline.monospacedDigit())
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Night's Events Subview

private struct NightEventsSection: View {
    @Query private var events: [RhythmEventRecord]

    init(sessionID: UUID) {
        let id: UUID? = sessionID
        _events = Query(
            filter: #Predicate<RhythmEventRecord> { $0.sessionID == id },
            sort: \RhythmEventRecord.start,
            order: .forward
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Ereignisse dieser Nacht")
                    .font(.headline)
                Spacer()
                Text("\(events.count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if events.isEmpty {
                Text("Keine Rhythmus-Ereignisse während dieser Nacht aufgezeichnet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(events) { event in
                        NavigationLink {
                            EventDetailView(record: event)
                        } label: {
                            EventRowView(record: event)
                                .padding(10)
                                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}
