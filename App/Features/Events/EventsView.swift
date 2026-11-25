import SwiftUI
import SwiftData
import H10Analysis

struct EventsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RhythmEventRecord.start, order: .reverse) private var events: [RhythmEventRecord]

    @State private var selectedFilter: RhythmEventType? = nil

    private var filteredEvents: [RhythmEventRecord] {
        guard let selectedFilter else { return events }
        return events.filter { $0.typeRaw == selectedFilter.rawValue }
    }

    private struct DayGroup: Identifiable {
        var id: Date { day }
        let day: Date
        let items: [RhythmEventRecord]
    }

    private var groupedByDay: [DayGroup] {
        let cal = Calendar.current
        let dict = Dictionary(grouping: filteredEvents) { record in
            cal.startOfDay(for: record.start)
        }
        return dict.keys.sorted(by: >).map { day in
            DayGroup(day: day, items: dict[day] ?? [])
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterBar
                Divider()

                if filteredEvents.isEmpty {
                    ContentUnavailableView {
                        Label("Keine Ereignisse", systemImage: "heart.text.square")
                    } description: {
                        Text(selectedFilter == nil
                             ? "Sobald der Polar H10 verbunden ist, werden erkannte Rhythmus-Ereignisse hier protokolliert."
                             : "Keine Ereignisse vom Typ „\(selectedFilter?.displayName ?? "")“ vorhanden.")
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    List {
                        ForEach(groupedByDay) { group in
                            Section(AppFormatters.dayHeader(group.day)) {
                                ForEach(group.items) { record in
                                    NavigationLink {
                                        EventDetailView(record: record)
                                    } label: {
                                        EventRowView(record: record)
                                    }
                                }
                                .onDelete { offsets in
                                    deleteItems(in: group.items, at: offsets)
                                }
                            }
                        }

                        Section {
                            Text(DisclaimerCopy.shortNotice)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Ereignisse")
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(title: "Alle", color: .red, isSelected: selectedFilter == nil) {
                    selectedFilter = nil
                }

                ForEach(RhythmEventType.allCases, id: \.self) { type in
                    filterChip(
                        title: type.displayName,
                        color: type.color,
                        isSelected: selectedFilter == type
                    ) {
                        selectedFilter = (selectedFilter == type) ? nil : type
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
        .background(Color(.systemBackground))
    }

    private func filterChip(title: String, color: Color, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isSelected ? Color.white : color)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(isSelected ? .white : .primary)
            .background(isSelected ? color : Color(.secondarySystemBackground), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func deleteItems(in items: [RhythmEventRecord], at offsets: IndexSet) {
        for idx in offsets {
            modelContext.delete(items[idx])
        }
    }
}

struct EventRowView: View {
    let record: RhythmEventRecord

    var body: some View {
        let eventType = record.type
        let color = eventType?.color ?? .secondary
        let icon = eventType?.iconName ?? "waveform.path.ecg"

        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 34, height: 34)
                .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(eventType?.displayName ?? record.typeRaw)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(AppFormatters.timeWithSeconds(record.start))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Text(record.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let hr = record.heartRate, hr.isFinite {
                Text("\(Int(hr.rounded()))")
                    .font(.caption.bold().monospacedDigit())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color(.tertiarySystemFill), in: Capsule())
            }
        }
        .padding(.vertical, 2)
    }
}
