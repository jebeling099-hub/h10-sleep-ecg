import SwiftUI

enum AppTab: Hashable {
    case live
    case sleep
    case events
    case settings
}

struct RootView: View {
    @AppStorage("hasAcceptedDisclaimer") private var hasAcceptedDisclaimer = false
    @State private var selectedTab: AppTab = .live

    var body: some View {
        TabView(selection: $selectedTab) {
            LiveView()
                .tabItem {
                    Label("Live", systemImage: "waveform.path.ecg")
                }
                .tag(AppTab.live)

            SleepView()
                .tabItem {
                    Label("Schlaf", systemImage: "moon.stars.fill")
                }
                .tag(AppTab.sleep)

            EventsView()
                .tabItem {
                    Label("Ereignisse", systemImage: "list.bullet.clipboard")
                }
                .tag(AppTab.events)

            SettingsView()
                .tabItem {
                    Label("Einstellungen", systemImage: "gearshape.fill")
                }
                .tag(AppTab.settings)
        }
        .sheet(isPresented: disclaimerPresentedBinding) {
            DisclaimerSheet {
                hasAcceptedDisclaimer = true
            }
            .interactiveDismissDisabled(true)
        }
    }

    private var disclaimerPresentedBinding: Binding<Bool> {
        Binding(
            get: { !hasAcceptedDisclaimer },
            set: { newValue in
                if !newValue {
                    hasAcceptedDisclaimer = true
                }
            }
        )
    }
}

private struct DisclaimerSheet: View {
    let onAccept: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 12) {
                        Image(systemName: "heart.text.square.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("H10 Sleep & ECG")
                                .font(.title2.bold())
                            Text("Wichtiger Hinweis")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("Kein Medizinprodukt")
                        .font(.headline)

                    Text(DisclaimerCopy.fullText)
                        .font(.body)
                        .foregroundStyle(.primary)

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Polar H10 Brustgurt vor dem Anlegen leicht befeuchten.", systemImage: "drop.fill")
                        Label("Alle Daten bleiben lokal auf diesem Gerät.", systemImage: "lock.shield.fill")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
                .padding()
            }
            .navigationTitle("Hinweis")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Button(action: onAccept) {
                    Text("Verstanden")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .padding()
                .background(.ultraThinMaterial)
            }
        }
    }
}
