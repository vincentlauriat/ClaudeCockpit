import Foundation

/// French-locale formatting helpers shared by every screen. Pure functions.
public enum FRFormat {
    public static let locale = Locale(identifier: "fr_FR")

    /// `1 234`, `12,3 k`, `1,2 M`, `3,4 G`
    public static func tokens(_ value: Int) -> String {
        let v = Double(value)
        switch abs(v) {
        case ..<10_000: return integer(value)
        case ..<1_000_000: return decimal(v / 1_000, digits: v < 100_000 ? 1 : 0) + " k"
        case ..<1_000_000_000: return decimal(v / 1_000_000, digits: v < 100_000_000 ? 1 : 0) + " M"
        default: return decimal(v / 1_000_000_000, digits: 1) + " G"
        }
    }

    /// `1 tour`, `2 tours`, `0 tour` — French agrees the singular on 0 and 1, unlike
    /// English. Pass an explicit plural for words that are not formed by adding an `s`
    /// (`cheval` / `chevaux`), and an empty `singular` suffix for invariables.
    ///
    ///     FRFormat.plural(1, "pièce jointe")   // "1 pièce jointe"
    ///     FRFormat.plural(3, "pièce jointe")   // "3 pièces jointes"
    public static func plural(_ count: Int, _ singular: String, _ pluralForm: String? = nil) -> String {
        let word = abs(count) < 2 ? singular : (pluralForm ?? defaultPlural(of: singular))
        return "\(integer(count)) \(word)"
    }

    /// Adds an `s` to every word of the phrase, which covers the cases this app uses
    /// (`pièce jointe` → `pièces jointes`). Words already ending in `s`, `x` or `z` are
    /// invariable and left alone.
    private static func defaultPlural(of phrase: String) -> String {
        phrase.split(separator: " ", omittingEmptySubsequences: false).map { word -> Substring in
            guard let last = word.last, !"sxz".contains(last) else { return word }
            return word + "s"
        }.joined(separator: " ")
    }

    public static func integer(_ value: Int) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: value)) ?? String(value)
    }

    public static func decimal(_ value: Double, digits: Int = 1) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.minimumFractionDigits = digits
        f.maximumFractionDigits = digits
        return f.string(from: NSNumber(value: value)) ?? String(format: "%.\(digits)f", value)
    }

    /// `12,34 $` / `12,34 €` — currency code `USD` or `EUR`.
    public static func money(_ value: Double, currency: String = "USD", digits: Int = 2) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .currency
        f.currencyCode = currency
        f.minimumFractionDigits = digits
        f.maximumFractionDigits = digits
        return f.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    /// `42 %` (value in 0…1) — `fraction: true` expects 0…1, otherwise 0…100.
    public static func percent(_ value: Double, fraction: Bool = true, digits: Int = 0) -> String {
        let pct = fraction ? value * 100 : value
        return decimal(pct, digits: digits) + " %"
    }

    /// `2 h 05`, `45 min`, `12 s`
    public static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(s) s" }
        let m = s / 60
        if m < 60 { return "\(m) min" }
        let h = m / 60, rm = m % 60
        if h < 48 { return String(format: "%d h %02d", h, rm) }
        let d = h / 24, rh = h % 24
        return "\(d) j \(rh) h"
    }

    /// `il y a 3 min`, `à l'instant`
    public static func relative(_ date: Date, now: Date = Date()) -> String {
        let delta = now.timeIntervalSince(date)
        if delta < 45 { return "à l'instant" }
        if delta < 3600 { return "il y a \(Int(delta / 60)) min" }
        if delta < 86_400 { return "il y a \(Int(delta / 3600)) h" }
        return "le " + shortDate(date)
    }

    /// `21 sept.`
    public static func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate("d MMM")
        return f.string(from: date)
    }

    /// `lun. 21`
    public static func weekday(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate("EEE d")
        return f.string(from: date)
    }

    /// `14:05`
    public static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// `21/09/2026 14:05`
    public static func dateTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.dateFormat = "dd/MM/yyyy HH:mm"
        return f.string(from: date)
    }
}
