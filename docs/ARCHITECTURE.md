# H10 Sleep & ECG – Architektur & Verträge

Verbindliche Schnittstellen für alle Mitwirkenden. **Es gibt auf dem Entwicklungsrechner keinen Swift-Compiler** – der Code wird erst in GitHub Actions (macOS, Xcode 16) gebaut. Darum: exakt diese Signaturen verwenden, konservatives Swift schreiben, keine exotischen APIs.

## Konventionen

- iOS Deployment Target **17.0**, Universal (iPhone + iPad), SwiftUI, SwiftData, Observation (`@Observable`).
- **Swift-Sprachmodus 5** (`SWIFT_VERSION = 5.0`), keine Strict-Concurrency-Fehler provozieren. Trotzdem sauber: UI-State nur auf dem `@MainActor`.
- Alle UI-Texte **Deutsch**. Keine `#Preview`-Blöcke (vermeidet Build-Probleme ohne Mock-Daten).
- Keine Dritt-Abhängigkeiten außer **PolarBleSdk** (SPM, `https://github.com/polarofficial/polar-ble-sdk`). Nur `App/Core/BLE/*` darf `import PolarBleSdk` (und dessen RxSwift) verwenden.
- `H10Analysis` ist plattformneutral (nur `Foundation`, optional `Accelerate` hinter `#if canImport(Accelerate)`), damit `swift test` auf macOS läuft.
- Zeitstempel überall: `Timestamp` = Sekunden seit 1970 (`Double`).

## Verzeichnisse & Besitzer

| Pfad | Besitzer |
|---|---|
| `project.yml`, `.github/workflows/*`, `README.md`, `App/Resources/*`, `sidestore-source.json` | build |
| `Packages/H10Analysis/**` (außer `Types.swift`) | dsp |
| `Packages/H10Analysis/Sources/H10Analysis/Types.swift` | coordinator (nur additive Änderungen) |
| `App/Core/BLE/**`, `App/Core/Engine/**` | core |
| `App/Core/Models/Records.swift` | coordinator (nur additive Änderungen) |
| `App/H10App.swift`, `App/Features/**`, `App/UIShared/**` | ui |

Xcode-Projekt wird per **XcodeGen** aus `project.yml` erzeugt; Target `H10Sleep`, alle Dateien unter `App/` sind Quellen, lokales Package `Packages/H10Analysis`.

## Paket `H10Analysis` (dsp)

Datentypen: siehe `Types.swift`. Zusätzlich implementiert dsp diese **öffentlichen** APIs:

```swift
/// Not thread-safe. The app calls it from ONE serial queue.
public final class RealtimeAnalyzer {
    public init(config: AnalyzerConfig = .default)
    public var config: AnalyzerConfig { get set }

    /// Feed ECG in arrival order (130 Hz). Returns newly detected/classified beats and
    /// newly COMPLETED events. Events carry a snippet (pre/post seconds) and are therefore
    /// emitted with a delay of about `snippetPostSeconds`.
    public func process(ecg: [ECGSample]) -> AnalyzerOutput
    /// Accelerometer (25 Hz, milli-g) – used for movement, respiration, artifact detection.
    public func process(acc: [ACCSample])
    /// RR from the standard HR service. Used only as fallback when no ECG is flowing
    /// (e.g. ECG stream not started yet). May return events (e.g. pause, brady/tachy).
    public func process(rr: [RRInterval]) -> AnalyzerOutput

    public var currentHeartRate: Double? { get }
    public var currentHRV: HRVMetrics? { get }          // updated after every beat
    public var signalQuality: SignalQuality { get }
    public var currentRespirationRate: Double? { get }
    /// Conditions currently active (e.g. .afibSuspected, .tachycardia) for live display.
    public var ongoingConditions: Set<RhythmEventType> { get }

    /// Completed 30-s epochs since the last call (always produced while data flows).
    public func drainEpochs() -> [EpochSummary]
    /// Discard internal buffers (e.g. after reconnect gap > 5 s).
    public func reset()
}

public struct AnalyzerOutput: Sendable {
    public var beats: [Beat]
    public var events: [RhythmEvent]
    public init(beats: [Beat] = [], events: [RhythmEvent] = [])
}

public enum SleepAnalyzer {
    /// Epochs sorted by time, may contain gaps. Returns stages aligned 1:1 with `epochs`.
    public static func analyze(epochs: [EpochSummary]) -> SleepAnalysisResult
}

public enum RRBackupAnalyzer {
    /// Build epochs from the H10 internal RR recording (used to fill gaps of the stream).
    public static func epochs(from rr: [RRInterval], epochSeconds: Double = 30) -> [EpochSummary]
    /// Merge: stream epochs win; backup epochs fill time ranges without stream epochs.
    public static func merge(stream: [EpochSummary], backup: [EpochSummary]) -> [EpochSummary]
}

public enum HRVCalculator {
    public static func rmssd(_ nnMs: [Double]) -> Double?
    public static func sdnn(_ nnMs: [Double]) -> Double?
    public static func pnn50(_ nnMs: [Double]) -> Double?
}
```

Algorithmen (Kurzfassung): Pan-Tompkins-R-Zacken (130 Hz), adaptiver QRS-Template-Vergleich (Korrelation + QRS-Breite) → VES/SVES; VES-Couplet/Bigeminus/Trigeminus aus Schlagfolge; AF-Verdacht aus RR-Unregelmäßigkeit (normierte RMSSD, Shannon-Entropie, Turning-Point-Ratio) über `afibWindowSeconds` ohne Ektopien; Brady/Tachy über `rateEventMinSeconds`; Pause > `pauseSeconds`; Artefakterkennung (Amplitudensättigung, Flatline, ACC-Bewegung, unplausible RR) – Artefakte erzeugen **keine** Rhythmus-Ereignisse. ACC → Aktivität pro Epoche + Atemfrequenz (Bandpass 0,1–0,5 Hz, Peak-Zählung/FFT). Schlaf: Schlaf/Wach aus Aktivität + HF (Cole-Kripke-artig), Phasen heuristisch (Tief: niedrige HF, hohe/stabile HRV, regelmäßige Atmung; REM: höhere HF-Variabilität, unregelmäßige Atmung, keine Bewegung; Leicht: Rest), Score 0–100 aus Komponenten: Schlafdauer (30), Effizienz (20), Tiefschlaf (15), REM (15), Erholung/Ruhepuls+HRV (10), Unruhe/Wachphasen (10).

## App-Kern (core)

```swift
enum ConnectionState: Equatable {
    case bluetoothOff, unauthorized, idle, scanning, connecting, connected, reconnecting
    var displayName: String { get }   // Deutsch
}

@MainActor @Observable
final class AppEngine {
    static let shared: AppEngine
    let modelContainer: ModelContainer       // RhythmEventRecord + SleepSessionRecord

    // Verbindung
    private(set) var connection: ConnectionState
    private(set) var deviceName: String?
    private(set) var deviceId: String?        // remembered in UserDefaults, auto-reconnect
    private(set) var batteryLevel: Int?
    func connect()                            // scan + connect to remembered or first H10 found
    func disconnect()
    func forgetDevice()

    // Live-Daten (Analyse läuft IMMER, sobald verbunden – auch im Hintergrund)
    private(set) var heartRate: Int?
    private(set) var hrv: HRVMetrics?
    private(set) var signalQuality: SignalQuality
    private(set) var respirationRate: Double?
    private(set) var rrHistory: [RRInterval]           // last 5 min
    private(set) var recentBeats: [Beat]               // last 15 s (for ECG markers)
    private(set) var ongoingConditions: Set<RhythmEventType>
    private(set) var latestEvent: RhythmEvent?
    private(set) var todayCounts: [RhythmEventType: Int]
    /// Last `seconds` of ECG for drawing (thread-safe snapshot, cheap; UI polls at ~30 fps).
    func ecgWindow(seconds: Double) -> [ECGSample]

    // Nacht
    private(set) var activeSession: SleepSessionRecord?
    private(set) var isFinishingSession: Bool
    func startNight()                                  // also starts H10 internal RR backup recording
    func stopNight() async -> UUID?                    // stops, fetches backup, merges, analyzes, saves; returns session id

    // Einstellungen (persisted in UserDefaults)
    var config: AnalyzerConfig
    var alertsEnabled: Bool                            // local notification on AF suspicion / long pause
}
```

Pipeline: PolarBleSdk-Callbacks → serielle Queue → `RealtimeAnalyzer` → Ereignisse als `RhythmEventRecord` speichern (mit `sessionID`, falls Nacht aktiv) → gedrosselte Updates (max. ~10 Hz) der `@Observable`-Properties auf dem MainActor. Epochen werden nur während einer Nacht gesammelt und regelmäßig (alle ~5 min) in `SleepSessionRecord.epochs` gesichert (Absturzsicherheit). Streams: HR (mit RR), ECG 130 Hz, ACC 25 Hz/2 G. Auto-Reconnect, Hintergrund-Modus `bluetooth-central`, State Restoration.

## UI (ui)

Tabs: **Live** (EKG-Papier 25 mm/s, HF, Signalqualität, Live-HRV-Panel mit RMSSD 60 s/5 min, SDNN, pNN50, RR-Tachogramm, Poincaré; Markierung von VES/SVES im EKG; Banner für laufende Zustände) · **Schlaf** (Nacht starten/stoppen, Liste der Nächte, Report mit Score-Ring, Komponenten, Hypnogramm, HF/HRV/Atem-Kurven über die Nacht) · **Ereignisse** (Protokoll, Filter nach Typ/Tag, Detail mit EKG-Snippet) · **Einstellungen** (Gerät, Grenzwerte, Hinweise, Haftungsausschluss „Kein Medizinprodukt“). UI liest Live-Daten aus `AppEngine.shared`, gespeicherte Daten via `@Query`.
