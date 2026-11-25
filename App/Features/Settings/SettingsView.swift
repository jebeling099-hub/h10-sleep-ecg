import SwiftUI
import H10Analysis

struct SettingsView: View {
    @Bindable private var engine = AppEngine.shared
    @State private var showForgetAlert = false

    private var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            Form {
                deviceSection
                thresholdsSection
                notificationsSection
                sideStoreSection
                aboutSection
            }
            .navigationTitle("Einstellungen")
            .alert("Gerät vergessen?", isPresented: $showForgetAlert) {
                Button("Abbrechen", role: .cancel) {}
                Button("Vergessen", role: .destructive) {
                    engine.forgetDevice()
                }
            } message: {
                Text("Der gespeicherte Polar H10 wird getrennt und nicht mehr automatisch verbunden.")
            }
        }
    }

    // MARK: - Device Section

    private var deviceSection: some View {
        Section("Polar H10") {
            HStack {
                Text("Status")
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(engine.connection.color)
                        .frame(width: 9, height: 9)
                    Text(engine.connection.displayName)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("Gerät")
                Spacer()
                Text(engine.deviceName ?? "Kein Gerät verbunden")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Akku")
                Spacer()
                if let battery = engine.batteryLevel {
                    Label("\(battery) %", systemImage: UIStyle.batteryIconName(for: battery))
                        .foregroundStyle(battery <= 15 ? .red : .secondary)
                        .monospacedDigit()
                } else {
                    Text("–")
                        .foregroundStyle(.secondary)
                }
            }

            if engine.connection.isActiveOrBusy {
                Button("Trennen") {
                    engine.disconnect()
                }
            } else {
                Button("Verbinden") {
                    engine.connect()
                }
            }

            if engine.deviceName != nil || engine.connection.isActiveOrBusy {
                Button("Gerät vergessen", role: .destructive) {
                    showForgetAlert = true
                }
            }
        }
    }

    // MARK: - Thresholds Section

    private var thresholdsSection: some View {
        Section {
            Stepper(
                value: $engine.config.bradycardiaBPM,
                in: 30...70,
                step: 1
            ) {
                HStack {
                    Text("Bradykardie")
                    Spacer()
                    Text("< \(Int(engine.config.bradycardiaBPM.rounded())) bpm")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            Stepper(
                value: $engine.config.tachycardiaBPM,
                in: 80...200,
                step: 5
            ) {
                HStack {
                    Text("Tachykardie")
                    Spacer()
                    Text("> \(Int(engine.config.tachycardiaBPM.rounded())) bpm")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            Stepper(
                value: $engine.config.pauseSeconds,
                in: 1.5...5.0,
                step: 0.1
            ) {
                HStack {
                    Text("Pause")
                    Spacer()
                    Text(String(format: "> %.1f s", engine.config.pauseSeconds))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        } header: {
            Text("Grenzwerte")
        } footer: {
            Text("Änderungen wirken sofort auf die laufende Analyse. Bradykardie und Tachykardie werden nach anhaltender Über- bzw. Unterschreitung gemeldet.")
        }
    }

    // MARK: - Notifications

    private var notificationsSection: some View {
        Section {
            Toggle("Hinweise bei AF-Verdacht & Pausen", isOn: $engine.alertsEnabled)
        } header: {
            Text("Mitteilungen")
        } footer: {
            Text("Sendet eine lokale Mitteilung bei Vorhofflimmern-Verdacht oder längeren Pausen.")
        }
    }

    // MARK: - SideStore Note

    private var sideStoreSection: some View {
        Section("SideStore & Aktualisierung") {
            VStack(alignment: .leading, spacing: 6) {
                Label("Automatisches Refresh alle 7 Tage", systemImage: "arrow.triangle.2.circlepath.circle")
                    .font(.subheadline.weight(.semibold))
                Text("Bei Installation über SideStore läuft die Signatur nach 7 Tagen ab. Halte LocalDevVPN aktiv oder aktualisiere die App rechtzeitig in SideStore, damit sie weiterhin startet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - About & Disclaimer

    private var aboutSection: some View {
        Section("Über & Haftungsausschluss") {
            HStack {
                Text("Version")
                Spacer()
                Text(appVersion)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Kein Medizinprodukt")
                    .font(.subheadline.bold())
                Text(DisclaimerCopy.fullText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }
}
