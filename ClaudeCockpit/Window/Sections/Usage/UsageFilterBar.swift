import SwiftUI
import UsageKit

/// Model families, project and date range. Every interaction writes the whole `UsageFilters`
/// struct once — the store recomputes the snapshot on each assignment.
struct UsageFilterBar: View {
    @Binding var filters: UsageFilters
    let availableFamilies: [ModelFamily]
    let availableProjects: [String]

    private var families: [ModelFamily] {
        availableFamilies.isEmpty ? ModelFamily.allCases : availableFamilies
    }

    /// `nil` (or empty) means every family — shown with every chip lit.
    private var selected: Set<ModelFamily> {
        guard let models = filters.models, !models.isEmpty else { return Set(families) }
        return models
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: "Modèles")
                    HStack(spacing: 6) {
                        ForEach(families) { family in
                            chip(family)
                        }
                    }
                }
                Divider().frame(height: 32)
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: "Projet")
                    Picker("", selection: projectBinding) {
                        Text("Tous les projets").tag(String?.none)
                        ForEach(availableProjects, id: \.self) { project in
                            Text(UsagePath.shorten(project)).tag(String?.some(project))
                        }
                    }
                    .labelsHidden()
                    .frame(minWidth: 220, maxWidth: 320)
                }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Période")
                Picker("", selection: rangeBinding) {
                    ForEach(DateRangeFilter.allCases) { range in
                        Text(range.frenchLabel).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .panelStyle()
    }

    private func chip(_ family: ModelFamily) -> some View {
        let isOn = selected.contains(family)
        return Button {
            toggle(family)
        } label: {
            Text(family.label)
                .font(.system(size: 12, weight: isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? family.color : Theme.slate)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(isOn ? family.color.opacity(0.16) : Color.clear))
                .overlay(
                    Capsule().stroke(isOn ? family.color.opacity(0.45) : Theme.cardStroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(isOn ? "Masquer \(family.label)" : "Afficher \(family.label)")
    }

    /// Deselecting the last family lands back on "every family" rather than on an empty
    /// dashboard the user could not escape.
    private func toggle(_ family: ModelFamily) {
        var set = selected
        if set.contains(family) { set.remove(family) } else { set.insert(family) }
        var next = filters
        next.models = (set.isEmpty || set == Set(families)) ? nil : set
        filters = next
    }

    private var projectBinding: Binding<String?> {
        Binding(
            get: { filters.project },
            set: { value in
                var next = filters
                next.project = value
                filters = next
            })
    }

    private var rangeBinding: Binding<DateRangeFilter> {
        Binding(
            get: { filters.range },
            set: { value in
                var next = filters
                next.range = value
                filters = next
            })
    }
}
