import AppKit
import SwiftUI
import CockpitShared
import QuotaKit

/// The menu-bar panel: the weekly gauge, the day's budget, three collapsible
/// sections and the action footer. Ported from ClaudeMenu's `UsagePanelView` onto
/// the cockpit store.
struct MenuBarPanelView: View {
    /// `false` renders the content without a scroll container. Used only by
    /// `PanelSizer`, which cannot lay out a `ScrollView`.
    var scrolls = true

    @Environment(CockpitStore.self) private var store
    @EnvironmentObject private var updater: UpdaterController
    @Environment(\.openWindow) private var openWindow

    @AppStorage(SettingsKey.panelSectionLimits) private var showLimits = true
    @AppStorage(SettingsKey.panelSectionToday) private var showToday = true
    @AppStorage(SettingsKey.panelSectionSavings) private var showSavings = true

    /// The panel's natural height, measured through AppKit (see `remeasure`).
    @State private var contentHeight: CGFloat = 0
    @State private var isRefreshing = false
    @State private var now = Date()

    // MARK: Derived

    private var week: Meter? { store.quota?.week }
    private var weekProjection: PaceProjection? { store.weekProjection }
    private var isFirstLoad: Bool { store.quota == nil && store.quotaState.isLoading }
    /// Hidden only when rtk has nothing to say and its source failed.
    private var showsSavingsSection: Bool {
        !(store.rtk == nil && store.rtkState.errorMessage != nil)
    }

    // MARK: Height

    /// The popover must fit under the menu bar whatever sections are open, and the
    /// cockpit keeps it deliberately shorter than the full strip: past ~720 pt the
    /// panel stops being a glance and the main window is the better place.
    private var maxHeight: CGFloat {
        let usable = (NSScreen.main?.visibleFrame.height ?? 800) - 24
        if SnapshotRunner.requestedDirectory != nil { return 1400 }   // full panel in screenshots
        return max(320, min(720, usable))
    }
    /// Never zero: a zero measurement would collapse the popover entirely, so an
    /// unmeasured panel falls back to a plausible height and scrolls.
    private var resolvedHeight: CGFloat {
        min(contentHeight > 0 ? contentHeight : Self.fallbackHeight, maxHeight)
    }
    private static let fallbackHeight: CGFloat = 560

    /// Re-measures a non-scrolling copy. Both environments have to be re-injected:
    /// the copy is built from scratch and reads the store and the updater.
    private func remeasure() {
        contentHeight = PanelSizer.naturalHeight(
            of: MenuBarPanelView(scrolls: false)
                .environment(store)
                .environmentObject(updater))
    }

    /// Everything that changes how tall the panel wants to be. Text that merely gets
    /// longer is not tracked: the scroll view absorbs a few points. Each entry flips
    /// at most a handful of times per run — a signature that churned on every refresh
    /// would re-host and re-lay out the whole panel behind the scenes each time.
    ///
    /// `isFirstLoad` is deliberately absent: the skeleton gives way either to a gauge
    /// (the meter count leaves -1) or to the "Indisponible" card (the error message
    /// appears), and both are already tracked.
    private var layoutSignature: String {
        [
            showLimits.description, showToday.description, showSavings.description,
            (store.quota?.weeklyMeters.count ?? -1).description,
            (store.quota?.other.count ?? -1).description,
            (store.quota?.session != nil).description,
            (store.quotaState.errorMessage != nil).description,
            showsSavingsSection.description,
            (store.usage != nil).description,
            (store.usageState.errorMessage != nil).description,
            (updater.pendingVersion != nil).description,
        ].joined(separator: "|")
    }

    // MARK: Body

    var body: some View {
        if scrolls {
            ScrollView(.vertical) { content }
                .scrollBounceBehavior(.basedOnSize)
                .frame(width: Theme.panelWidth, height: resolvedHeight)
                .onAppear {
                    store.openWindowHandler = { openWindow(id: MainWindowView.windowID) }
                    store.start()
                    now = Date()
                    remeasure()
                }
                .onChange(of: layoutSignature) { _, _ in remeasure() }
        } else {
            content.frame(width: Theme.panelWidth)
        }
    }

    private var content: some View {
        VStack(spacing: 8) {
            if isFirstLoad {
                QuotaSkeleton(rows: 2)
            } else {
                QuotaHeroCard(week: week, projection: weekProjection, isLoading: store.quotaState.isLoading)
            }
            if let message = store.quotaState.errorMessage {
                SourceBanner(
                    kind: .warning,
                    message: QuotaFormat.bannerMessage(message),
                    action: { Task { await store.refreshQuota(force: true) } })
            }
            QuotaBudgetCard(projection: weekProjection)
            limitsSection
            todaySection
            if showsSavingsSection { savingsSection }
            footer
        }
        .padding(10)
    }

    // MARK: Sections

    private var limitsSection: some View {
        DisclosureCard(
            title: "Limites Anthropic",
            icon: "gauge.with.dots.needle.33percent",
            iconColor: Theme.blue,
            expanded: $showLimits
        ) {
            if let gauge = store.quota {
                if let session = gauge.session {
                    QuotaMeterRow(meter: session, now: now)
                    Divider().opacity(0.4)
                }
                ForEach(Array(gauge.weeklyMeters.enumerated()), id: \.element.id) { index, meter in
                    if index > 0 { Divider().opacity(0.4) }
                    QuotaMeterRow(meter: meter, now: now)
                }
                if !gauge.other.isEmpty {
                    Divider().opacity(0.4)
                    InfoRow(
                        label: "Autres compartiments",
                        value: FRFormat.integer(gauge.other.count),
                        note: gauge.other.map {
                            "\(QuotaFormat.prettyModel($0.name)) \(FRFormat.percent($0.utilization, fraction: false))"
                        }.joined(separator: ", ") + " — détail dans la fenêtre.")
                }
            } else {
                InfoRow(
                    label: "Lecture des compteurs",
                    value: store.quotaState.errorMessage == nil ? "en cours…" : "indisponible")
            }
        }
    }

    private var todaySection: some View {
        DisclosureCard(
            title: "Aujourd'hui",
            icon: "text.alignleft",
            iconColor: Theme.violet,
            expanded: $showToday
        ) {
            if let usage = store.usage {
                InfoRow(label: "Coût local du jour", value: store.money(usage.costTodayUSD), tint: Theme.blue)
                Divider().opacity(0.4)
                InfoRow(
                    label: "Tokens du jour", value: FRFormat.tokens(usage.tokensToday),
                    note: "entrée + sortie + cache, tous modèles confondus")
                Divider().opacity(0.4)
                InfoRow(
                    label: "Sessions cette semaine", value: FRFormat.integer(usage.sessionsThisWeekTotal),
                    note: "\(FRFormat.integer(usage.sessionsLastWeekTotal)) la semaine précédente")
            } else if let message = store.usageState.errorMessage {
                SourceBanner(kind: .error, message: message, action: { Task { await store.refreshUsage() } })
                    .padding(.vertical, 6)
            } else {
                InfoRow(label: "Lecture des transcripts", value: "en cours…")
            }
        }
    }

    private var savingsSection: some View {
        DisclosureCard(
            title: "Économies RTK",
            icon: "scissors",
            iconColor: Theme.emerald,
            expanded: $showSavings
        ) {
            if let rtk = store.rtk {
                let week = rtk.last7Days.reduce(0) { $0 + $1.savedTokens }
                InfoRow(
                    label: "Tokens économisés aujourd'hui", value: FRFormat.tokens(rtk.today.savedTokens),
                    tint: Theme.emerald,
                    note: "\(FRFormat.percent(rtk.today.savingsPct, fraction: false, digits: 1)) de \(FRFormat.tokens(rtk.today.inputTokens)) tokens, sur \(FRFormat.integer(rtk.today.count)) commandes filtrées")
                Divider().opacity(0.4)
                InfoRow(
                    label: "Sur 7 jours", value: FRFormat.tokens(week),
                    note: "cumul des sept derniers jours")
                Divider().opacity(0.4)
                InfoRow(
                    label: "Depuis l'installation", value: FRFormat.tokens(rtk.allTime.savedTokens),
                    note: "\(FRFormat.percent(rtk.allTime.savingsPct, fraction: false, digits: 1)) économisés sur \(FRFormat.integer(rtk.allTime.count)) commandes")
            } else {
                InfoRow(
                    label: "Économies rtk", value: "aucune donnée",
                    note: "rtk n'a encore rien enregistré")
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Button {
                store.openMainWindow()
            } label: {
                ActionRow(
                    icon: "macwindow", iconColor: Theme.accent,
                    title: "Ouvrir le cockpit",
                    subtitle: "Usage, quotas, RTK et skills")
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider().opacity(0.4).padding(.leading, 46)

            Button {
                guard !isRefreshing else { return }
                isRefreshing = true
                Task {
                    await store.refreshAll()
                    now = Date()
                    isRefreshing = false
                }
            } label: {
                ActionRow(
                    icon: "arrow.clockwise", iconColor: Theme.blue,
                    title: isRefreshing ? "Actualisation en cours…" : "Rafraîchir",
                    subtitle: refreshSubtitle
                ) {
                    if isRefreshing { ProgressView().controlSize(.small) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing)

            Divider().opacity(0.4).padding(.leading, 46)

            Button {
                updater.checkForUpdates()
            } label: {
                ActionRow(
                    icon: updater.pendingVersion == nil ? "arrow.down.circle" : "arrow.down.circle.fill",
                    iconColor: Theme.violet,
                    title: updater.pendingVersion.map { "Installer la version \($0)" }
                        ?? "Rechercher des mises à jour",
                    subtitle: "Version \(updater.currentVersion)"
                ) {
                    if let pending = updater.pendingVersion {
                        Text(pending)
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Theme.violet.opacity(0.18), in: Capsule())
                            .foregroundStyle(Theme.violet)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!updater.canCheck)

            Divider().opacity(0.4).padding(.leading, 46)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                ActionRow(icon: "xmark.circle", iconColor: .red, title: "Quitter")
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
        }
        .padding(.vertical, 4)
        .card()
    }

    /// Says when the gauge was last read, and when the next read becomes possible.
    private var refreshSubtitle: String {
        var parts: [String] = []
        if let fetched = store.quota?.fetchedAt {
            parts.append("Compteurs lus \(FRFormat.relative(fetched, now: now))")
        } else {
            parts.append("Compteurs jamais lus")
        }
        let wait = store.quotaNextAllowed.timeIntervalSince(now)
        if wait > 0 {
            parts.append("prochaine lecture dans \(FRFormat.duration(wait))")
        }
        return parts.joined(separator: " · ")
    }
}
