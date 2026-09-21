import SwiftUI
import CockpitShared
import QuotaKit

// MARK: - Formatting & guards

/// Wording, tones and guards shared by the menu-bar panel, the overview and the
/// quotas screen. Kept in one place so the three screens never disagree on what a
/// meter is called or on when a projection may be shown.
enum QuotaFormat {
    /// `nimbus_quill` → `Nimbus Quill`
    static func prettyModel(_ name: String) -> String {
        name.split(whereSeparator: { $0 == "_" || $0 == "-" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// `Session en cours (5 h)`, `Tous modèles (7 jours)`, `Modèle Opus (7 jours)`
    static func label(for meter: Meter) -> String {
        if meter.isSession { return "Session en cours (5 h)" }
        if meter.name == "all" { return "Tous modèles (7 jours)" }
        return "Modèle \(prettyModel(meter.name)) (7 jours)"
    }

    /// `lun. 21 à 14:05`
    static func dayTime(_ date: Date) -> String {
        "\(FRFormat.weekday(date)) à \(FRFormat.time(date))"
    }

    /// Extrapolating from the first minutes of a window turns a normal start into an
    /// absurd rate, so every sentence and every tone goes through this guard: it hands
    /// back the projection only once it means something.
    static func meaningful(_ projection: PaceProjection?) -> PaceProjection? {
        guard let projection, projection.isMeaningful else { return nil }
        return projection
    }

    /// Only a meaningful projection may darken a tone.
    static func tone(used: Double, projection: PaceProjection?) -> Color {
        Theme.tone(used: used, landing: meaningful(projection)?.landing)
    }

    /// "Se réinitialise lun. 21 à 14:05, dans 2 j 6 h."
    static func resetSentence(_ projection: PaceProjection) -> String {
        "Se réinitialise \(dayTime(projection.resetsAt)), dans \(FRFormat.duration(projection.hoursLeft * 3600))."
    }

    /// The sentence describing a pace, or the reason there is none yet.
    static func paceSentence(raw: PaceProjection?, window: String = "la fenêtre") -> String {
        guard let raw else { return "Aucune date de réinitialisation communiquée pour ce compteur." }
        guard let projection = meaningful(raw) else {
            return "\(window.prefix(1).uppercased() + window.dropFirst()) est à peine entamée : le rythme n'est pas encore significatif."
        }
        return PaceSentence.pace(projection)
    }

    /// A French hint for a failing quota read. The messages come from `CredentialError`
    /// and `QuotaError` and are already French: they say « jeton » when the token is
    /// missing, expired or refused, and « identifiants » when it is unreadable.
    static func hint(for message: String) -> String? {
        let lower = message.lowercased()
        if lower.contains("jeton") || lower.contains("identifiants") {
            return "Connectez-vous dans Claude Code pour activer les quotas."
        }
        if lower.contains("429") || lower.contains("limite") {
            return "Les chiffres affichés restent les derniers lus."
        }
        return nil
    }

    /// Banner text: the error, plus its hint when there is one.
    static func bannerMessage(_ message: String) -> String {
        guard let hint = hint(for: message) else { return message }
        return "\(message) \(hint)"
    }
}

// MARK: - Hero

/// The weekly gauge: big percent, reset countdown, bar and pace sentence.
/// Shared verbatim by the panel and the overview.
struct QuotaHeroCard: View {
    let week: Meter?
    /// Raw projection — the card applies the meaningfulness guard itself.
    let projection: PaceProjection?
    var isLoading: Bool = false
    var percentSize: CGFloat = 42

    private var tone: Color {
        QuotaFormat.tone(used: week?.utilization ?? 0, projection: projection)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                if let week {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(FRFormat.decimal(week.utilization, digits: 0))
                            .font(.display(percentSize, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(tone)
                        Text("%")
                            .font(.display(percentSize * 0.48))
                            .foregroundStyle(tone)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isLoading ? "Lecture…" : "Indisponible")
                            .font(.display(22, weight: .bold))
                            .foregroundStyle(.secondary)
                        Text("Quota hebdomadaire")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 8)
                if let projection {
                    VStack(alignment: .trailing, spacing: 2) {
                        SectionLabel(text: "Réinitialisation")
                        Text("dans " + FRFormat.duration(projection.hoursLeft * 3600))
                            .font(.system(size: 16, weight: .bold))
                            .monospacedDigit()
                        Text(QuotaFormat.dayTime(projection.resetsAt))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            if let week {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tone)
                    Text("Quota hebdomadaire consommé")
                        .font(.system(size: 13, weight: .medium))
                }
                SegmentedBar(fraction: week.utilization / 100, color: tone)
            }
            if projection != nil {
                Text(QuotaFormat.paceSentence(raw: projection, window: "la semaine"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .card()
    }
}

// MARK: - Daily budget

/// "Budget du jour": the share of the remaining quota that today may spend.
struct QuotaBudgetCard: View {
    let projection: PaceProjection?

    private var sentence: String {
        guard let projection else { return "En attente des compteurs Anthropic." }
        if projection.remaining <= 0 { return "Plus rien à dépenser avant la réinitialisation." }
        let remaining = FRFormat.percent(projection.remaining, fraction: false)
        let days = FRFormat.decimal(projection.daysLeft, digits: 1)
        return "Part quotidienne du quota restant (\(remaining)) répartie sur les \(days) jours qui restent."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: "Budget du jour")
            if let projection {
                Text(FRFormat.percent(projection.evenSharePerDay, fraction: false, digits: 2))
                    .font(.display(24, weight: .bold))
                    .monospacedDigit()
            }
            Text(sentence)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .card()
    }
}

// MARK: - Meters

/// One meter as a compact `InfoRow` — the panel's "Limites Anthropic" section.
struct QuotaMeterRow: View {
    let meter: Meter
    let now: Date

    private var raw: PaceProjection? { UsageMath.projection(for: meter, now: now) }

    private var note: String {
        guard let raw else { return "Aucune date de réinitialisation communiquée." }
        guard let projection = QuotaFormat.meaningful(raw) else {
            return QuotaFormat.resetSentence(raw) + " Fenêtre trop récente pour projeter un rythme fiable."
        }
        return QuotaFormat.resetSentence(raw) + "\n" + PaceSentence.rates(projection)
    }

    var body: some View {
        InfoRow(
            label: QuotaFormat.label(for: meter),
            value: FRFormat.percent(meter.utilization, fraction: false) + " utilisé",
            tint: QuotaFormat.tone(used: meter.utilization, projection: raw),
            note: note)
    }
}

/// One meter as a full-width card — the quotas screen.
struct QuotaMeterCard: View {
    let meter: Meter
    let now: Date

    private var raw: PaceProjection? { UsageMath.projection(for: meter, now: now) }
    private var tone: Color { QuotaFormat.tone(used: meter.utilization, projection: raw) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(QuotaFormat.label(for: meter))
                    .font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 12)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(FRFormat.decimal(meter.utilization, digits: 0))
                        .font(.display(30, weight: .bold))
                        .monospacedDigit()
                    Text("%").font(.display(15))
                }
                .foregroundStyle(tone)
            }
            SegmentedBar(fraction: meter.utilization / 100, color: tone)
            if let raw {
                Text(QuotaFormat.resetSentence(raw))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let projection = QuotaFormat.meaningful(raw) {
                    Text(PaceSentence.rates(projection))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(PaceSentence.pace(projection))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(tone)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Fenêtre trop récente pour projeter un rythme fiable.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Aucune date de réinitialisation communiquée pour ce compteur.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .card()
    }
}

// MARK: - Loading

/// Compact placeholder shown while the gauge has never been read.
struct QuotaSkeleton: View {
    var rows: Int = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Lecture des compteurs Anthropic…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            ForEach(0..<max(1, rows), id: \.self) { _ in
                Capsule().fill(Theme.track).frame(height: 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .card()
    }
}
