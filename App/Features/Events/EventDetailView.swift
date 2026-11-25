import SwiftUI
import SwiftData
import H10Analysis

struct EventDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let record: RhythmEventRecord

    @State private var gain: ECGGain = .standard10
    @State private var showDeleteConfirmation = false
    @State private var decodedSnippet: ECGSnippet?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                summaryCard
                snippetCard
                explanationCard
                disclaimerFooter
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(record.type?.displayName ?? "Ereignis")
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
        .alert("Ereignis löschen?", isPresented: $showDeleteConfirmation) {
            Button("Abbrechen", role: .cancel) {}
            Button("Löschen", role: .destructive) {
                modelContext.delete(record)
                dismiss()
            }
        } message: {
            Text("Dieses Ereignis und der zugehörige EKG-Ausschnitt werden dauerhaft entfernt.")
        }
        .onAppear {
            if decodedSnippet == nil {
                decodedSnippet = record.snippet
            }
        }
    }

    private var summaryCard: some View {
        let type = record.type
        let duration = max(0, record.end.timeIntervalSince(record.start))

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: type?.iconName ?? "waveform.path.ecg")
                    .font(.title2)
                    .foregroundStyle(type?.color ?? .red)
                    .frame(width: 44, height: 44)
                    .background((type?.color ?? .red).opacity(0.15), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    Text(type?.displayName ?? record.typeRaw)
                        .font(.headline)
                    Text(AppFormatters.shortDateTime(record.start))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let hr = record.heartRate, hr.isFinite {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(Int(hr.rounded())) bpm")
                            .font(.headline.monospacedDigit())
                        Text("Herzfrequenz")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            Text(record.detail)
                .font(.body)

            if duration >= 1.0 {
                HStack {
                    Text("Dauer")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.1f s", duration))
                        .monospacedDigit()
                }
                .font(.subheadline)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var snippetCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("EKG-Ausschnitt")
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

            if let snippet = decodedSnippet, !snippet.samplesUV.isEmpty {
                StaticECGSnippetView(snippet: snippet, gain: gain, height: 210)
                Text("Horizontal wischen, um den gesamten EKG-Streifen zu betrachten.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Für dieses Ereignis ist kein EKG-Ausschnitt gespeichert.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100)
                    .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var explanationCard: some View {
        if let explanation = record.type?.explanation {
            VStack(alignment: .leading, spacing: 8) {
                Label("Erläuterung", systemImage: "info.circle")
                    .font(.headline)
                Text(explanation)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var disclaimerFooter: some View {
        Text(DisclaimerCopy.shortNotice)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }
}
