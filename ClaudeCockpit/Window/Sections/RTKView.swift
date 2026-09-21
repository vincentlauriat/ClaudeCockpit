import AppKit
import SwiftUI
import CockpitShared
import RTKKit

/// The RTK screen: a port of the RTKInfos dashboard onto the cockpit's theme.
///
/// Emerald only — savings are never judged in red or orange; low-signal
/// commands fall back to neutral mist through `Theme.savingsIntensity`.
struct RTKView: View {
    @Environment(CockpitStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showTrace = true

    private var snapshot: RTKSnapshot? { store.rtk }

    /// rtk is simply not installed (or has no history yet): an install hint,
    /// not an error.
    ///
    /// `RTKService.snapshot()` throws `RTKError.databaseNotFound` exactly when
    /// no database resolves, so an unresolved path plus a failing state is the
    /// same condition, read without matching on the message text.
    private var databaseMissing: Bool {
        store.rtkState.errorMessage != nil && store.rtkDatabaseURL == nil
    }
    private var otherFailure: String? {
        guard let message = store.rtkState.errorMessage, !databaseMissing else { return nil }
        return message
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                header
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        banners
                        databaseCard
                        if let snapshot, !databaseMissing {
                            heroSection(snapshot)
                            todayStrip(snapshot)
                            weekSection(snapshot)
                            allTimeSection(snapshot)
                            byCommandSection(snapshot)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(minWidth: 460)

            if showTrace {
                RTKTracePanel(records: snapshot?.recent ?? [], isStale: databaseMissing)
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 460)
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing))
            }
        }
        .background(Theme.background)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "leaf.fill")
                .font(.system(size: 14))
                .foregroundStyle(Theme.emerald)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Économies rtk")
                    .font(.display(15))
                    .foregroundStyle(Theme.ink)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.slate)
            }
            Spacer()
            Button {
                Task { await store.refreshRTK() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Relire la base rtk")
            .accessibilityLabel("Relire la base rtk")

            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { showTrace.toggle() }
            } label: {
                Image(systemName: showTrace ? "terminal.fill" : "terminal")
            }
            .buttonStyle(.plain)
            .opacity(showTrace ? 1 : 0.4)
            .help(showTrace ? "Masquer la trace live" : "Afficher la trace live")
            .accessibilityLabel("Panneau de trace live")
            .accessibilityValue(showTrace ? "affiché" : "masqué")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Theme.panel)
    }

    private var subtitle: String {
        if databaseMissing { return "rtk non détecté" }
        if let date = store.rtkState.lastSuccess { return "Relu \(FRFormat.relative(date))" }
        if store.rtkState.isLoading { return "Lecture de la base…" }
        return "En attente"
    }

    // MARK: - Banners

    @ViewBuilder
    private var banners: some View {
        if databaseMissing {
            SourceBanner(
                kind: .info,
                message: "rtk n'est pas installé ou n'a pas encore d'historique. Installez-le depuis https://github.com/rtk-ai/rtk, lancez quelques commandes, ou indiquez le chemin de history.db dans les réglages.",
                action: { openRTKPage() },
                actionTitle: "Ouvrir la page rtk")
        } else if let otherFailure {
            SourceBanner(
                kind: .error,
                message: otherFailure,
                action: { Task { await store.refreshRTK() } })
        } else if let snapshot, let last = snapshot.lastActivity, inactiveDays(since: last) >= 7 {
            SourceBanner(
                kind: .warning,
                message: "Aucune commande rtk depuis \(inactiveDays(since: last)) jours.")
        }
    }

    private func openRTKPage() {
        guard let url = URL(string: "https://github.com/rtk-ai/rtk") else { return }
        NSWorkspace.shared.open(url)
    }

    private func inactiveDays(since date: Date) -> Int {
        Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
    }

    // MARK: - Database card

    private var databaseCard: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel(text: "Base de données")
                Text(store.rtkDatabaseURL?.path ?? "Aucun chemin résolu")
                    .font(.data(11))
                    .foregroundStyle(Theme.slate)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 12)
            Button("Révéler dans le Finder") { revealDatabase() }
                .controlSize(.small)
                .disabled(store.rtkDatabaseURL == nil)
        }
        .padding(14)
        .card()
    }

    /// Selects `history.db` in the Finder, falling back to its directory when
    /// the file is gone.
    private func revealDatabase() {
        guard let url = store.rtkDatabaseURL else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    // MARK: - Hero

    private func heroSection(_ snapshot: RTKSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            CompressionGauge(
                input: snapshot.allTime.inputTokens,
                output: snapshot.allTime.outputTokens)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(FRFormat.tokens(snapshot.allTime.savedTokens))
                        .font(.display(44, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text(FRFormat.percent(snapshot.allTime.savingsPct, fraction: false))
                        .font(.display(20, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.emerald)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Theme.emerald.opacity(0.12), in: Capsule())
                }
                SectionLabel(text: "Jetons économisés · depuis toujours")
            }
        }
        .panelStyle()
    }

    // MARK: - Today

    private func todayStrip(_ snapshot: RTKSnapshot) -> some View {
        HStack(spacing: 10) {
            SectionLabel(text: "Aujourd'hui")
            if snapshot.today.isEmpty {
                Text("Aucune commande rtk aujourd'hui.")
                    .font(.data(11))
                    .foregroundStyle(Theme.slate)
            } else {
                Text(FRFormat.tokens(snapshot.today.savedTokens) + " économisés")
                    .font(.data(12))
                    .foregroundStyle(Theme.emerald)
                Text("·").foregroundStyle(Theme.mist)
                Text("\(FRFormat.integer(snapshot.today.count)) cmd")
                    .font(.data(12))
                    .foregroundStyle(Theme.slate)
                Text("·").foregroundStyle(Theme.mist)
                Text(FRFormat.percent(snapshot.today.savingsPct, fraction: false))
                    .font(.data(12))
                    .foregroundStyle(Theme.savingsIntensity(snapshot.today.savingsPct))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .card()
    }

    // MARK: - Last 7 days

    private func weekSection(_ snapshot: RTKSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: "Sept derniers jours")
                Spacer()
                Text(FRFormat.tokens(snapshot.last7Days.reduce(0) { $0 + $1.savedTokens }) + " économisés")
                    .font(.data(11))
                    .foregroundStyle(Theme.emerald)
            }
            WeekIntensityChart(days: snapshot.last7Days)
        }
        .panelStyle()
    }

    // MARK: - All time

    private func allTimeSection(_ snapshot: RTKSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "Depuis toujours")
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 170), spacing: 12)],
                spacing: 12
            ) {
                StatTile(
                    label: "Commandes",
                    value: FRFormat.integer(snapshot.allTime.count),
                    note: "filtrées par rtk",
                    icon: "number")
                StatTile(
                    label: "Entrée",
                    value: FRFormat.tokens(snapshot.allTime.inputTokens),
                    note: "avant filtrage",
                    icon: "arrow.down.to.line.compact")
                StatTile(
                    label: "Sortie",
                    value: FRFormat.tokens(snapshot.allTime.outputTokens),
                    note: "après filtrage",
                    icon: "arrow.up.right")
                StatTile(
                    label: "Économisé",
                    value: FRFormat.tokens(snapshot.allTime.savedTokens),
                    note: FRFormat.percent(snapshot.allTime.savingsPct, fraction: false) + " de l'entrée",
                    tint: Theme.emerald,
                    icon: "leaf.fill")
            }
        }
        .panelStyle()
    }

    // MARK: - By command

    private func byCommandSection(_ snapshot: RTKSnapshot) -> some View {
        let maxSaved = snapshot.byCommand.map(\.savedTokens).max() ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Par commande")
            if snapshot.byCommand.isEmpty {
                Text("Aucune commande enregistrée pour le moment.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.slate)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(snapshot.byCommand.enumerated()), id: \.element.id) { index, stat in
                    CommandImpactRow(rank: index + 1, stat: stat, maxSaved: maxSaved)
                    if index < snapshot.byCommand.count - 1 {
                        Divider().opacity(0.4)
                    }
                }
            }
        }
        .panelStyle()
    }
}
