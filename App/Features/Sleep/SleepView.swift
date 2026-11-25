import SwiftUI
import SwiftData
import H10Analysis

struct SleepView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SleepSessionRecord.startDate, order: .reverse) private var sessions: [SleepSessionRecord]

    private let engine = AppEngine.shared
    @State private var openedSession: SleepSessionRecord?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    nightControlCard
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

                Section("Aufgezeichnete Nächte") {
                    let completedSessions = sessions.filter { $0.id != engine.activeSession?.id }
                    if completedSessions.isEmpty {
                        Text("Noch keine abgeschlossenen Nächte vorhanden.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(completedSessions) { session in
                            NavigationLink {
                                SleepReportView(record: session)
                            } label: {
                                SleepSessionRow(record: session)
                            }
                        }
                        .onDelete { offsets in
                            deleteSessions(completedSessions, at: offsets)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Schlaf")
            .navigationDestination(item: $openedSession) { record in
                SleepReportView(record: record)
            }
        }
    }

    // MARK: - Night Control Card

    @ViewBuilder
    private var nightControlCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            if engine.isFinishingSession {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Nacht wird ausgewertet…")
                        .font(.headline)
                    Text("Backup-RR-Daten werden vom Polar H10 geladen und analysiert.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else if let active = engine.activeSession {
                HStack {
                    Label("Schlafaufzeichnung läuft", systemImage: "moon.zzz.fill")
                        .font(.headline)
                        .foregroundStyle(.indigo)
                    Spacer()
                    Circle()
                        .fill(engine.connection.color)
                        .frame(width: 10, height: 10)
                }

                TimelineView(.periodic(from: .now, by: 1.0)) { context in
                    let elapsed = context.date.timeIntervalSince(active.startDate)
                    Text(AppFormatters.timer(seconds: elapsed))
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 4)
                }

                HStack {
                    Label(engine.connection.displayName, systemImage: engine.connection.iconName)
                    Spacer()
                    if let hr = engine.heartRate {
                        Label("\(hr) bpm", systemImage: "heart.fill")
                            .foregroundStyle(.red)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                hintsBox

                Button {
                    Task {
                        if let finishedID = await engine.stopNight() {
                            openSession(withID: finishedID)
                        }
                    }
                } label: {
                    Label("Aufwachen", systemImage: "sun.max.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            } else {
                HStack {
                    Label("Bereit für die Nacht", systemImage: "moon.stars.fill")
                        .font(.headline)
                    Spacer()
                    Text(engine.connection.displayName)
                        .font(.caption)
                        .foregroundStyle(engine.connection.color)
                }

                if engine.connection != .connected {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Polar H10 ist noch nicht verbunden. Bitte Gurt anlegen und befeuchten.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                hintsBox

                Button {
                    engine.startNight()
                } label: {
                    Label("Schlaf starten", systemImage: "moon.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var hintsBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("iPhone über Nacht ans Ladekabel anschließen.", systemImage: "battery.100.bolt")
            Label("App nicht beenden – Analyse läuft im Hintergrund weiter.", systemImage: "app.badge.checkmark")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Helpers

    private func openSession(withID id: UUID) {
        if let found = sessions.first(where: { $0.id == id }) {
            openedSession = found
            return
        }
        let descriptor = FetchDescriptor<SleepSessionRecord>(
            predicate: #Predicate<SleepSessionRecord> { $0.id == id }
        )
        if let fetched = try? modelContext.fetch(descriptor).first {
            openedSession = fetched
        }
    }

    private func deleteSessions(_ list: [SleepSessionRecord], at offsets: IndexSet) {
        for idx in offsets {
            modelContext.delete(list[idx])
        }
    }
}

private struct SleepSessionRow: View {
    let record: SleepSessionRecord

    var body: some View {
        HStack(spacing: 14) {
            scoreBadge

            VStack(alignment: .leading, spacing: 4) {
                Text(AppFormatters.nightRowDate(record.startDate))
                    .font(.subheadline.weight(.semibold))

                HStack(spacing: 10) {
                    Label(AppFormatters.duration(minutes: record.totalSleepMinutes), systemImage: "bed.double.fill")
                    if record.vesCount > 0 || record.svesCount > 0 {
                        Text("VES \(record.vesCount) · SVES \(record.svesCount)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var scoreBadge: some View {
        let score = record.score
        let color = score.map { UIStyle.scoreColor(for: $0) } ?? .secondary

        return ZStack {
            Circle()
                .stroke(color.opacity(0.25), lineWidth: 4)
            if let score {
                Circle()
                    .trim(from: 0, to: CGFloat(max(0, min(100, score))) / 100.0)
                    .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(score)")
                    .font(.subheadline.bold().monospacedDigit())
            } else {
                Text("–")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, height: 44)
    }
}
