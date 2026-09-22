import SwiftUI
import UsageKit

/// Editable per-family pricing: one row per `ModelFamily`, one column per rate, in USD
/// per million tokens.
///
/// Edits land in a local draft rather than straight into `store.pricing`: the store's
/// `didSet` persists the JSON *and* kicks off a full usage recompute, which would run
/// once per committed field. The draft is pushed to the store when a field commits
/// (blur or return) — `TextField(value:format:)` writes its binding then, not on every
/// keystroke.
struct PricingEditorView: View {
    @Environment(CockpitStore.self) private var store
    @State private var draft: PricingSettings = .default

    private var isDirty: Bool { draft != store.pricing }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                ratesTable
                explanation
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { draft = store.pricing }
        .onChange(of: draft) { _, _ in apply() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Tarifs par famille de modèle")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Rétablir les tarifs par défaut") { draft = .default }
                    .disabled(draft == .default)
            }
            Text("Dollars par million de tokens. Toute modification s'applique immédiatement au coût estimé, partout dans l'application.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.slate)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Grid

    private var ratesTable: some View {
        Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 10) {
            GridRow {
                Text("")
                columnHeader("Entrée")
                columnHeader("Sortie")
                columnHeader("Création cache")
                columnHeader("Lecture cache")
            }
            Divider().gridCellColumns(5).gridCellUnsizedAxes(.horizontal)
            ForEach(ModelFamily.allCases) { family in
                GridRow {
                    Text(family.rawValue.uppercased())
                        .font(.label())
                        .tracking(1.1)
                        .foregroundStyle(Theme.slate)
                        .gridColumnAlignment(.leading)
                    let rates = binding(for: family)
                    rateCell(rates.inputPerMTok)
                    rateCell(rates.outputPerMTok)
                    rateCell(rates.cacheWritePerMTok)
                    rateCell(rates.cacheReadPerMTok)
                }
            }
        }
        .panelStyle()
    }

    private func columnHeader(_ title: String) -> some View {
        Text(title)
            .font(.label(10))
            .foregroundStyle(Theme.slate)
    }

    private func rateCell(_ value: Binding<Double>) -> some View {
        HStack(spacing: 2) {
            Text("$").foregroundStyle(Theme.slate)
            TextField("", value: value, format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 72)
        }
        .font(.system(size: 12))
    }

    // MARK: Explanation

    private var explanation: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                Text("Les compteurs de tokens viennent des transcripts de Claude Code (~/.claude/projects) : ce sont les vrais chiffres renvoyés par l'API, pas une estimation.")
                Text("Le coût, lui, est estimé : seul le tarif « Entrée » est publié par modèle. Sortie ≈ 5 × Entrée, Création cache (TTL 5 min) ≈ 1,25 × Entrée, Lecture cache ≈ 0,1 × Entrée.")
                Text("« Rétablir les tarifs par défaut » restaure les valeurs codées dans PricingSettings.default, qui ne sont pas forcément les tarifs du jour.")
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.slate)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Comment le coût est calculé")
                .font(.system(size: 12, weight: .semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelStyle()
    }

    // MARK: Plumbing

    private func binding(for family: ModelFamily) -> Binding<ModelPricing> {
        Binding(
            get: { draft.pricing(for: family) },
            set: { draft.setPricing($0, for: family) }
        )
    }

    private func apply() {
        guard isDirty else { return }
        store.pricing = draft
    }
}
