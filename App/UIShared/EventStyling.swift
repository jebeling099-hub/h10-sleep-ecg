import SwiftUI
import H10Analysis

extension RhythmEventType {
    var color: Color {
        switch self {
        case .ves:
            return .orange
        case .sves:
            return .yellow
        case .vesCouplet:
            return .red
        case .bigeminy, .trigeminy:
            return .orange
        case .afibSuspected:
            return .red
        case .bradycardia:
            return .blue
        case .tachycardia:
            return .pink
        case .pause:
            return .purple
        }
    }

    var iconName: String {
        switch self {
        case .ves, .sves:
            return "waveform.path.ecg"
        case .vesCouplet, .bigeminy, .trigeminy:
            return "exclamationmark.triangle.fill"
        case .afibSuspected:
            return "heart.text.square.fill"
        case .bradycardia:
            return "arrow.down.heart.fill"
        case .tachycardia:
            return "bolt.heart.fill"
        case .pause:
            return "pause.circle.fill"
        }
    }

    var severityOrder: Int {
        switch self {
        case .pause: return 0
        case .afibSuspected: return 1
        case .vesCouplet: return 2
        case .bigeminy: return 3
        case .trigeminy: return 4
        case .tachycardia: return 5
        case .bradycardia: return 6
        case .ves: return 7
        case .sves: return 8
        }
    }
}

extension SignalQuality {
    var color: Color {
        switch self {
        case .good: return .green
        case .fair: return .yellow
        case .poor: return .orange
        case .noContact: return .red
        }
    }

    var iconName: String {
        switch self {
        case .good: return "wifi"
        case .fair: return "wifi"
        case .poor: return "wifi.exclamationmark"
        case .noContact: return "wifi.slash"
        }
    }
}

extension ConnectionState {
    var color: Color {
        switch self {
        case .connected: return .green
        case .scanning, .connecting, .reconnecting: return .orange
        case .idle: return .secondary
        case .bluetoothOff, .unauthorized: return .red
        }
    }

    var iconName: String {
        switch self {
        case .connected: return "checkmark.circle.fill"
        case .scanning, .connecting, .reconnecting: return "dot.radiowaves.left.and.right"
        case .idle: return "bolt.slash.circle"
        case .bluetoothOff, .unauthorized: return "exclamationmark.triangle.fill"
        }
    }

    var isActiveOrBusy: Bool {
        switch self {
        case .connected, .connecting, .scanning, .reconnecting:
            return true
        case .idle, .bluetoothOff, .unauthorized:
            return false
        }
    }
}

extension SleepStage {
    var color: Color {
        switch self {
        case .awake: return .orange
        case .rem: return .purple
        case .light: return .cyan
        case .deep: return .indigo
        }
    }

    /// Y-axis order for hypnogram: Deep (0) -> Light (1) -> REM (2) -> Awake (3).
    var chartLevel: Int {
        switch self {
        case .deep: return 0
        case .light: return 1
        case .rem: return 2
        case .awake: return 3
        }
    }

    static func fromChartLevel(_ level: Int) -> SleepStage {
        switch level {
        case 0: return .deep
        case 1: return .light
        case 2: return .rem
        default: return .awake
        }
    }
}

enum UIStyle {
    static func scoreColor(for score: Int) -> Color {
        if score >= 80 {
            return .green
        } else if score >= 60 {
            return .orange
        } else {
            return .red
        }
    }

    static func batteryIconName(for level: Int) -> String {
        switch level {
        case 88...100: return "battery.100"
        case 63..<88: return "battery.75"
        case 38..<63: return "battery.50"
        case 13..<38: return "battery.25"
        default: return "battery.0"
        }
    }
}
