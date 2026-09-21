import SwiftUI
import CockpitShared
import UsageKit

/// Named sessions in the current filter range, most recent first. A row opens its detail sheet.
struct UsageSessionsList: View {
    let sessions: [SessionSummary]
    let money: (Double) -> String
    @State private var selected: SessionSummary?

    private static let maxRows = 30

    var body: some View {
        let shown = Array(sessions.prefix(Self.maxRows))
        return VStack(alignment: .leading, spacing: 16) {
            SectionLabel(text: "Sessions")
            if shown.isEmpty {
                Text("Aucune session sur cette période.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.slate)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
            } else {
                VStack(spacing: 0) {
                    header
                    ForEach(shown) { session in
                        Button { selected = session } label: { rowView(session) }
                            .buttonStyle(.plain)
                        if session.id != shown.last?.id {
                            Divider().overlay(Theme.cardStroke)
                        }
                    }
                }
                if sessions.count > Self.maxRows {
                    Text("\(Self.maxRows) sessions affichées sur \(FRFormat.integer(sessions.count)) — affinez la période ou le projet pour voir les autres.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.slate)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelStyle()
        .sheet(item: $selected) { session in
            SessionDetailSheet(session: session, money: money)
        }
    }

    private var header: some View {
        HStack {
            Text("TITRE")
            Spacer()
            Text("PROJET").frame(width: 180, alignment: .leading)
            Text("DERNIER TOUR").frame(width: 130, alignment: .leading)
            Text("TOURS").frame(width: 60, alignment: .trailing)
            Text("TOKENS").frame(width: 90, alignment: .trailing)
            Text("COÛT").frame(width: 80, alignment: .trailing)
        }
        .font(.label(10))
        .tracking(1.2)
        .foregroundStyle(Theme.slate)
        .padding(.bottom, 8)
    }

    private func rowView(_ session: SessionSummary) -> some View {
        HStack {
            Text(session.displayName)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)
            Text(UsagePath.shorten(session.cwd))
                .frame(width: 180, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.head)
            Text(FRFormat.dateTime(session.lastSeen))
                .frame(width: 130, alignment: .leading)
            Text(FRFormat.integer(session.turnCount))
                .frame(width: 60, alignment: .trailing)
            Text(FRFormat.tokens(session.totalTokens))
                .frame(width: 90, alignment: .trailing)
            Text(money(session.estimatedCostUSD))
                .foregroundStyle(Theme.blue)
                .frame(width: 80, alignment: .trailing)
        }
        .font(.system(size: 12))
        .monospacedDigit()
        .foregroundStyle(Theme.slate)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

/// Detail sheet for one session: identity, time range, token and cost totals.
struct SessionDetailSheet: View {
    let session: SessionSummary
    let money: (Double) -> String
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.displayName)
                    .font(.display(18))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                Spacer(minLength: 16)
                Button("Fermer", action: dismiss.callAsFunction)
                    .keyboardShortcut(.defaultAction)
            }
            Text(UsagePath.shorten(session.cwd))
                .font(.system(size: 12))
                .foregroundStyle(Theme.slate)
                .lineLimit(1)
                .truncationMode(.head)
            Text("\(FRFormat.dateTime(session.firstSeen)) → \(FRFormat.dateTime(session.lastSeen)) · \(FRFormat.duration(session.lastSeen.timeIntervalSince(session.firstSeen)))")
                .font(.system(size: 11))
                .foregroundStyle(Theme.slate)
            Divider().overlay(Theme.cardStroke)
            LazyVGrid(columns: columns, spacing: 12) {
                StatTile(
                    label: "Tours",
                    value: FRFormat.integer(session.turnCount),
                    note: session.modelsUsed.joined(separator: ", "))
                StatTile(
                    label: "Entrée",
                    value: FRFormat.tokens(session.inputTokens),
                    note: "tokens",
                    tint: UsagePalette.input)
                StatTile(
                    label: "Sortie",
                    value: FRFormat.tokens(session.outputTokens),
                    note: "tokens",
                    tint: UsagePalette.output)
                StatTile(
                    label: "Cache lu",
                    value: FRFormat.tokens(session.cacheReadTokens),
                    note: "tokens",
                    tint: UsagePalette.cacheRead)
                StatTile(
                    label: "Cache créé",
                    value: FRFormat.tokens(session.cacheCreationTokens),
                    note: "tokens",
                    tint: UsagePalette.cacheCreation)
                StatTile(
                    label: "Coût estimé",
                    value: money(session.estimatedCostUSD),
                    note: "approximatif",
                    tint: Theme.blue)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(minWidth: 700, minHeight: 360)
        .background(Theme.background)
    }
}
