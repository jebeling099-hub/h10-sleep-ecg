import Foundation
import UserNotifications
import H10Analysis

/// Manages rate-limited local notifications for critical rhythm events
/// (atrial fibrillation suspicion and long pauses).
@MainActor
final class AlertNotifier {
    private var lastNotificationByType: [RhythmEventType: Date] = [:]
    private let cooldownSeconds: TimeInterval = 600 // 10 minutes per event type

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notifyIfNeeded(for event: RhythmEvent, enabled: Bool) {
        guard enabled else { return }
        guard event.type == .afibSuspected || event.type == .pause else { return }

        let now = Date()
        if let last = lastNotificationByType[event.type],
           now.timeIntervalSince(last) < cooldownSeconds {
            return
        }
        lastNotificationByType[event.type] = now

        let content = UNMutableNotificationContent()
        content.title = "H10 Hinweis: \(event.type.displayName)"
        content.body = event.detail.isEmpty
            ? "\(event.type.explanation) Kein Medizinprodukt."
            : "\(event.detail) (Kein Medizinprodukt.)"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "h10.event.\(event.id.uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
