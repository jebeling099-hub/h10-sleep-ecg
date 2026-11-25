import Foundation

enum ConnectionState: Equatable {
    case bluetoothOff
    case unauthorized
    case idle
    case scanning
    case connecting
    case connected
    case reconnecting

    var displayName: String {
        switch self {
        case .bluetoothOff:
            return "Bluetooth aus"
        case .unauthorized:
            return "Bluetooth nicht erlaubt"
        case .idle:
            return "Getrennt"
        case .scanning:
            return "Suche Polar H10…"
        case .connecting:
            return "Verbinde…"
        case .connected:
            return "Verbunden"
        case .reconnecting:
            return "Verbinde neu…"
        }
    }
}
