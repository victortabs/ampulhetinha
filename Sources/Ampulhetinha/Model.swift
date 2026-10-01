import CoreGraphics
import Foundation

/// Um timer ativo, recente ou vindo do app Lembretes.
struct TimerItem: Codable, Identifiable, Equatable {
    static let defaultTitle = "Timer"

    var id: String
    var title: String
    var startDate: Date
    var fireDate: Date
    /// `calendarItemIdentifier` do EKReminder correspondente.
    var reminderID: String?
    /// `calendarItemExternalIdentifier` (sobrevive a ressincronizações do iCloud).
    var reminderExternalID: String?
    /// Quando o timer terminou (nil enquanto está correndo).
    var finishedAt: Date?

    // Só para itens vindos do app Lembretes; não são persistidos.
    var isExternal = false
    var listName: String?

    private enum CodingKeys: String, CodingKey {
        case id, title, startDate, fireDate, reminderID, reminderExternalID, finishedAt
    }

    init(title: String, start: Date, fireDate: Date) {
        self.id = UUID().uuidString
        self.title = title
        self.startDate = start
        self.fireDate = fireDate
    }

    init(external r: ExternalReminder) {
        self.id = "ek:" + r.id
        self.title = r.title
        self.startDate = r.due
        self.fireDate = r.due
        self.reminderID = r.id
        self.reminderExternalID = r.externalID
        self.isExternal = true
        self.listName = r.listName
    }

    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? Self.defaultTitle : t
    }

    var durationMinutes: Int { max(1, Int((fireDate.timeIntervalSince(startDate) / 60).rounded())) }
}

/// Cópia leve de um EKReminder (EKReminder não pode atravessar threads).
struct ExternalReminder {
    var id: String
    var externalID: String?
    var title: String
    var due: Date
    var listName: String
}

/// Converte a distância arrastada em minutos: 400 pt para a primeira hora, depois 100 pt por hora.
enum DurationMapper {
    static let deadZone: CGFloat = 22
    static let firstHour: CGFloat = 400
    static let perHourAfter: CGFloat = 100

    /// Minutos escolhidos e o início do timer (recuado até o minuto cheio quando o alvo é um horário redondo).
    static func choice(distance: CGFloat, fine: Bool, now: Date = Date()) -> (minutes: Int, start: Date) {
        guard distance > deadZone else { return (0, now) }
        let d = distance - deadZone
        let hours = d <= firstHour ? d / firstHour : 1 + (d - firstHour) / perHourAfter
        return snap(max(1, Double(hours) * 60), fine: fine, now: now)
    }

    /// Com ⌥: de minuto em minuto. Sem: degraus a partir de agora (5, 10, 15…; 15 em 15 depois da primeira
    /// hora) intercalados com os que caem em horário redondo (às 12:17, 3 min → 12:20 e 8 min → 12:25),
    /// o que estiver mais perto.
    static func snap(_ raw: Double, fine: Bool, now: Date) -> (minutes: Int, start: Date) {
        let step: Double
        if fine { step = 1 } else if raw < 60 { step = 5 } else { step = 15 }
        let relative = max(fine ? 1 : step, (raw / step).rounded() * step)
        guard !fine else { return (Int(relative), now) }

        // Redondos contam do minuto cheio, para disparar no :00; e só valem a partir de 1 min de distância.
        let cal = Calendar.current
        let floored = cal.dateInterval(of: .minute, for: now)?.start ?? now
        let minuteOfDay = Double(cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now))
        let off = minuteOfDay.truncatingRemainder(dividingBy: step)
        var round = ((raw + off) / step).rounded() * step - off
        while round * 60 - now.timeIntervalSince(floored) < 60 { round += step }

        if abs(round - raw) <= abs(relative - raw) {
            return (Int(round), floored)
        }
        return (Int(relative), now)
    }
}

enum Fmt {
    private static func plural(_ n: Int, _ one: String, _ many: String) -> String {
        "\(n) \(n == 1 ? one : many)"
    }

    /// "50 minutos", "1 hora e 5 minutos", "2 dias e 3 horas"
    static func longDuration(minutes total: Int) -> String {
        let d = total / 1440, h = (total % 1440) / 60, m = total % 60
        var parts: [String] = []
        if d > 0 { parts.append(plural(d, "dia", "dias")) }
        if h > 0 { parts.append(plural(h, "hora", "horas")) }
        if m > 0 && d == 0 { parts.append(plural(m, "minuto", "minutos")) }
        guard let last = parts.last else { return "0 minutos" }
        return parts.count == 1 ? last : parts.dropLast().joined(separator: ", ") + " e " + last
    }

    /// "30 min", "2 h 30 min", "1 d 3 h", "45 s"
    static func shortRemaining(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(max(0, Int(seconds.rounded(.up)))) s" }
        let total = Int((seconds / 60).rounded(.up))
        let d = total / 1440, h = (total % 1440) / 60, m = total % 60
        if d > 0 { return h > 0 ? "\(d) d \(h) h" : "\(d) d" }
        if h > 0 { return m > 0 ? "\(h) h \(m) min" : "\(h) h" }
        return "\(m) min"
    }

    /// Barra de menus: "2h 25m", "25m", "45s"
    static func compact(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(max(0, Int(seconds.rounded(.up))))s" }
        let total = Int((seconds / 60).rounded(.up))
        let d = total / 1440, h = (total % 1440) / 60, m = total % 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        return "\(m)m"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.setLocalizedDateFormatFromTemplate("EEEdMMM")
        return f
    }()

    static func time(_ date: Date) -> String { timeFormatter.string(from: date) }

    /// "às" (hoje), "amanhã" ou "sex., 3 de out."
    static func dayPrefix(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) { return "às" }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(date, inSameDayAs: tomorrow) {
            return "amanhã"
        }
        return dayFormatter.string(from: date)
    }

    /// "às 08:45", "amanhã às 08:45"
    static func at(_ date: Date, now: Date = Date()) -> String {
        let prefix = dayPrefix(date, now: now)
        return prefix == "às" ? "às \(time(date))" : "\(prefix) às \(time(date))"
    }
}
