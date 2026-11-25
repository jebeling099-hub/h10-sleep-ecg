import Foundation
import H10Analysis

enum AppFormatters {
    private static let germanLocale = Locale(identifier: "de_DE")

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = germanLocale
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let timeWithSecondsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = germanLocale
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let dayHeaderFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = germanLocale
        f.dateFormat = "EEEE, d. MMMM yyyy"
        return f
    }()

    private static let shortDateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = germanLocale
        f.dateFormat = "dd.MM.yyyy, HH:mm"
        return f
    }()

    private static let nightRowDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = germanLocale
        f.dateFormat = "EE, d. MMM yyyy"
        return f
    }()

    static func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    static func time(timestamp: Timestamp?) -> String {
        guard let timestamp else { return "–" }
        return timeFormatter.string(from: Date(timeIntervalSince1970: timestamp))
    }

    static func timeWithSeconds(_ date: Date) -> String {
        timeWithSecondsFormatter.string(from: date)
    }

    static func shortDateTime(_ date: Date) -> String {
        shortDateTimeFormatter.string(from: date)
    }

    static func nightRowDate(_ date: Date) -> String {
        nightRowDateFormatter.string(from: date)
    }

    static func dayHeader(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return "Heute"
        }
        if cal.isDateInYesterday(date) {
            return "Gestern"
        }
        return dayHeaderFormatter.string(from: date)
    }

    static func duration(minutes: Double) -> String {
        let total = max(0, Int(minutes.rounded()))
        let hours = total / 60
        let mins = total % 60
        if hours > 0 {
            return "\(hours) h \(mins) min"
        }
        return "\(mins) min"
    }

    static func timer(seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    static func value(_ number: Double?, decimals: Int = 0, unit: String = "") -> String {
        guard let number, number.isFinite else { return "–" }
        let formatted = String(format: "%.\(decimals)f", number)
        return unit.isEmpty ? formatted : "\(formatted) \(unit)"
    }

    static func percent(_ fraction: Double) -> String {
        let clamped = max(0, min(1, fraction))
        return "\(Int((clamped * 100).rounded())) %"
    }
}

enum DisclaimerCopy {
    static let shortNotice = "Kein Medizinprodukt – alle Auswertungen dienen nur der persönlichen Information und ersetzen keine ärztliche Diagnose."

    static let fullText = """
    H10 Sleep & ECG ist kein Medizinprodukt und nicht für medizinische Diagnosen, Behandlungen oder die Überwachung lebensbedrohlicher Zustände zugelassen.

    Die automatische Erkennung von Herzrhythmus-Auffälligkeiten (wie VES, SVES, Pausen oder Vorhofflimmern-Verdacht) sowie die Schlafphasen-Auswertung basieren auf heuristischen Algorithmen und können falsch-positive oder falsch-negative Ergebnisse liefern.

    Bei Beschwerden, Schwindel, Brustschmerzen, Atemnot oder Unsicherheit wenden Sie sich bitte umgehend an eine Ärztin, einen Arzt oder den Notruf.
    """
}
