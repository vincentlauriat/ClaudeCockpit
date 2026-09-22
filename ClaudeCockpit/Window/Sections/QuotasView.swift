import SwiftUI
import CockpitShared
import QuotaKit

/// The limits screen: one card per meter at full width, then the read details and a
/// manual refresh.
struct QuotasView: View {
    @Environment(CockpitStore.self) private var store
    @State private var now = Date()
    @State private var isRefreshing = false
    @AppStorage("section.otherBuckets") private var showOtherBuckets = false

    private var meters: [Meter] {
        guard let gauge = store.quota else { return [] }
        var list: [Meter] = []
        if let session = gauge.session { list.append(session) }
        list.append(contentsOf: gauge.weeklyMeters)
        return list
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let message = store.quotaState.errorMessage {
                    SourceBanner(
                        kind: .warning,
                        message: QuotaFormat.bannerMessage(message),
                        action: { refresh() })
                }
                if store.quota == nil && store.quotaState.isLoading {
                    QuotaSkeleton(rows: 4)
                } else if meters.isEmpty {
                    Text("Aucun compteur n'a encore été lu.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 20)
                } else {
                    VStack(spacing: 12) {
                        ForEach(meters) { meter in
                            QuotaMeterCard(meter: meter, now: now)
                        }
                    }
                    if let other = store.quota?.other, !other.isEmpty {
                        DisclosureCard(
                            title: "Autres compartiments (\(other.count))",
                            icon: "shippingbox",
                            iconColor: Theme.slate,
                            expanded: $showOtherBuckets
                        ) {
                            Text(QuotaFormat.bucketNote)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.bottom, 4)
                            ForEach(Array(other.enumerated()), id: \.element.id) { index, meter in
                                if index > 0 { Divider().opacity(0.4) }
                                InfoRow(
                                    label: QuotaFormat.label(for: meter),
                                    value: FRFormat.percent(meter.utilization, fraction: false) + " utilisé",
                                    note: "Clé API : \(meter.key)")
                            }
                        }
                    }
                }
                details
            }
            .padding(24)
        }
        .onAppear { now = Date() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Quotas").font(.display(24, weight: .bold))
                Text(caption).font(.system(size: 12)).foregroundStyle(Theme.slate)
            }
            Spacer()
        }
    }

    private var caption: String {
        guard let fetched = store.quota?.fetchedAt else { return "Compteurs jamais lus" }
        return "Mis à jour \(FRFormat.relative(fetched, now: now))"
    }

    // MARK: Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Détails")
            InfoRow(
                label: "Dernière lecture",
                value: store.quota.map { FRFormat.dateTime($0.fetchedAt) } ?? "—",
                note: "Les compteurs viennent de l'API d'usage d'Anthropic, via le jeton de Claude Code.")
            Divider().opacity(0.4)
            InfoRow(
                label: "Prochaine lecture autorisée",
                value: nextAllowedValue,
                note: "Les lectures sont espacées pour ne pas déclencher de limitation côté Anthropic.")
            Divider().opacity(0.4)
            HStack {
                Button {
                    refresh()
                } label: {
                    Label(isRefreshing ? "Lecture en cours…" : "Rafraîchir maintenant",
                          systemImage: "arrow.clockwise")
                }
                .disabled(isRefreshing)
                if isRefreshing { ProgressView().controlSize(.small) }
                Spacer()
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelStyle()
    }

    private var nextAllowedValue: String {
        let wait = store.quotaNextAllowed.timeIntervalSince(now)
        if wait <= 0 { return "maintenant" }
        return "dans \(FRFormat.duration(wait)) · \(FRFormat.time(store.quotaNextAllowed))"
    }

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            await store.refreshQuota(force: true)
            now = Date()
            isRefreshing = false
        }
    }
}
