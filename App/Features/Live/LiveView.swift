import SwiftUI
import H10Analysis

struct LiveView: View {
    private let engine = AppEngine.shared
    @State private var gain: ECGGain = .standard10

    private let pointsPerMM: CGFloat = 4.0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    headerCard
                    bannersSection
                    ecgSection
                    todayCountsCard
                    HRVPanelView(hrv: engine.hrv, rrHistory: engine.rrHistory)
                }
                .padding()
            }
            .navigationTitle("Live")
            .background(Color(.systemGroupedBackground))
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(engine.connection.color)
                        .frame(width: 10, height: 10)
                    Text(engine.connection.displayName)
                        .font(.subheadline.weight(.semibold))
                }

                Spacer()

                if let name = engine.deviceName {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let battery = engine.batteryLevel {
                    Label("\(battery) %", systemImage: UIStyle.batteryIconName(for: battery))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(battery <= 15 ? .red : .secondary)
                }
            }

            Divider()

            HStack(alignment: .center, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "heart.fill")
                        .font(.title2)
                        .foregroundStyle(engine.heartRate != nil ? .red : .secondary)
                    Text(engine.heartRate.map { "\($0)" } ?? "–")
                        .font(.system(size: 52, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("bpm")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: engine.signalQuality.iconName)
                            .foregroundStyle(engine.signalQuality.color)
                        Text(engine.signalQuality.displayName)
                            .font(.subheadline.weight(.medium))
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "lungs.fill")
                            .foregroundStyle(.teal)
                        Text(AppFormatters.value(engine.respirationRate, decimals: 0, unit: "/min"))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !engine.connection.isActiveOrBusy {
                Button {
                    engine.connect()
                } label: {
                    Label("Polar H10 verbinden", systemImage: "antenna.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Banners

    @ViewBuilder
    private var bannersSection: some View {
        let sortedConditions = engine.ongoingConditions.sorted { $0.severityOrder < $1.severityOrder }
        if !sortedConditions.isEmpty {
            VStack(spacing: 8) {
                ForEach(sortedConditions, id: \.self) { condition in
                    HStack(spacing: 12) {
                        Image(systemName: condition.iconName)
                            .font(.title3)
                            .foregroundStyle(.white)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Aktiver Hinweis: \(condition.displayName)")
                                .font(.subheadline.bold())
                                .foregroundStyle(.white)
                            Text(condition.explanation)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.9))
                                .lineLimit(2)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(condition.color.gradient, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }

        if let latest = engine.latestEvent {
            HStack(spacing: 12) {
                Image(systemName: latest.type.iconName)
                    .font(.title3)
                    .foregroundStyle(latest.type.color)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Letztes Ereignis: \(latest.type.displayName)")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(AppFormatters.timeWithSeconds(Date(timeIntervalSince1970: latest.start)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(latest.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(latest.type.color.opacity(0.35), lineWidth: 1)
            )
        }
    }

    // MARK: - Live ECG

    private var ecgSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Live-EKG")
                        .font(.headline)
                    Text("25 mm/s · \(gain.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Picker("Verstärkung", selection: $gain) {
                    ForEach(ECGGain.allCases) { option in
                        Text("\(Int(option.mmPerMV)) mm").tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)
            }

            GeometryReader { geo in
                let width = max(120, geo.size.width)
                let windowSeconds = max(2.0, Double(width / pointsPerMM) / ECGPaperCanvas.mmPerSecond)

                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
                    let samples = engine.ecgWindow(seconds: windowSeconds)
                    if samples.isEmpty {
                        ZStack {
                            ECGPaperCanvas(
                                samples: [],
                                beats: [],
                                startTime: 0,
                                durationSeconds: windowSeconds,
                                gain: gain,
                                pointsPerMM: pointsPerMM
                            )
                            VStack(spacing: 8) {
                                Image(systemName: "waveform.path.ecg")
                                    .font(.title2)
                                    .foregroundStyle(.secondary)
                                Text("Keine Daten – Gurt anlegen und befeuchten")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal)
                            }
                        }
                    } else {
                        let endTime = samples.last?.t ?? Date().timeIntervalSince1970
                        let startTime = endTime - windowSeconds
                        ECGPaperCanvas(
                            samples: samples,
                            beats: engine.recentBeats,
                            startTime: startTime,
                            durationSeconds: windowSeconds,
                            gain: gain,
                            pointsPerMM: pointsPerMM
                        )
                    }
                }
            }
            .frame(height: 210)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            )

            HStack(spacing: 14) {
                markerLegend(label: "V", title: "VES", color: .orange, textColor: .white)
                markerLegend(label: "S", title: "SVES", color: .yellow, textColor: .black)
                markerLegend(label: "A", title: "Artefakt", color: .gray, textColor: .white)
                Spacer()
            }
            .font(.caption)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func markerLegend(label: String, title: String, color: Color, textColor: Color) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(textColor)
                .frame(width: 16, height: 16)
                .background(color, in: RoundedRectangle(cornerRadius: 4))
            Text(title)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Today's Counts

    private var todayCountsCard: some View {
        let nonZeroTypes = RhythmEventType.allCases.filter { (engine.todayCounts[$0] ?? 0) > 0 }

        return VStack(alignment: .leading, spacing: 10) {
            Text("Heute erkannte Ereignisse")
                .font(.headline)

            if nonZeroTypes.isEmpty {
                Text("Heute bisher keine Auffälligkeiten registriert.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                    ForEach(nonZeroTypes, id: \.self) { type in
                        HStack(spacing: 6) {
                            Image(systemName: type.iconName)
                                .foregroundStyle(type.color)
                                .font(.caption)
                            Text(type.displayName)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer(minLength: 2)
                            Text("\(engine.todayCounts[type] ?? 0)")
                                .font(.subheadline.bold().monospacedDigit())
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}
