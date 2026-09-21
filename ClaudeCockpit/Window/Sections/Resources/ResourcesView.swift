import AppKit
import SwiftUI
import CockpitShared
import SkillsKit

/// One screen reused for skills, agents and commands.
///
/// Left: the resources of the selected kind at the selected level. Right: the
/// detail pane with the markdown content and the copy / move / import /
/// reveal / delete actions. Skills additionally expose the read-only plugin
/// catalogue through the « Plugins » toggle.
struct ResourcesView: View {
    let kind: ResourceKind
    @Environment(CockpitStore.self) private var store

    @State private var levelID: String = ResourceLevel.global.id
    @State private var search = ""
    @State private var selectionID: String?
    @State private var pluginSelectionID: String?
    @State private var showPlugins = false

    private var inventory: SkillsInventory? { store.skills }
    private var levels: [ResourceLevel] { inventory?.levels ?? [.library, .global] }
    private var level: ResourceLevel { levels.first { $0.id == levelID } ?? .global }

    /// Resources of this kind at the selected level, filtered by the search
    /// field and sorted by name.
    private var items: [ClaudeResource] {
        guard let inventory else { return [] }
        let all = inventory.resources(kind: kind, level: level)
        let filtered = query.isEmpty ? all : all.filter {
            $0.name.lowercased().contains(query) || ($0.description ?? "").lowercased().contains(query)
        }
        return filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var pluginItems: [PluginResource] {
        guard let inventory else { return [] }
        let all = inventory.plugins
        let filtered = query.isEmpty ? all : all.filter {
            $0.qualifiedName.lowercased().contains(query) || ($0.description ?? "").lowercased().contains(query)
        }
        return filtered.sorted { $0.qualifiedName.localizedStandardCompare($1.qualifiedName) == .orderedAscending }
    }

    private var query: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Resolved from the whole inventory, so the selection survives a refresh
    /// and a transfer that changed the level.
    private var selectedResource: ClaudeResource? {
        guard let selectionID else { return nil }
        return inventory?.resources.first { $0.id == selectionID }
    }
    private var selectedPlugin: PluginResource? {
        guard let pluginSelectionID else { return nil }
        return inventory?.plugins.first { $0.id == pluginSelectionID }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let message = store.skillsState.errorMessage {
                SourceBanner(kind: .error, message: message, action: { Task { await store.refreshSkills() } })
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
            }
            HSplitView {
                listPane
                    .frame(minWidth: 250, idealWidth: 320, maxWidth: 460)
                detailPane
                    .frame(minWidth: 400)
            }
        }
        .background(Theme.background)
        .onChange(of: kind) { _, _ in
            search = ""
            selectionID = nil
            pluginSelectionID = nil
            showPlugins = false
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: kind == .skill ? "sparkles" : (kind == .agent ? "person.2.fill" : "terminal.fill"))
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.violet)
                    .accessibilityHidden(true)
                Text(kind.pluralLabel)
                    .font(.display(15))
                    .foregroundStyle(Theme.ink)

                Picker("Niveau", selection: $levelID) {
                    ForEach(levels, id: \.id) { level in
                        Text(level.label).tag(level.id)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
                .disabled(showPlugins)

                searchField

                Spacer(minLength: 8)

                if kind == .skill {
                    Toggle(isOn: $showPlugins) {
                        Label("Plugins", systemImage: "puzzlepiece.extension.fill")
                    }
                    .toggleStyle(.button)
                    .help("Afficher le catalogue de skills fourni par les plugins (lecture seule)")
                }

                Button {
                    Task { await store.refreshSkills() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Relire les ressources")
                .accessibilityLabel("Relire les ressources")
            }
            levelBadges
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Theme.panel)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.slate)
            TextField("Rechercher", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.mist)
                .accessibilityLabel("Effacer la recherche")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .frame(maxWidth: 240)
    }

    /// One badge per level with its count, doubling as a shortcut.
    private var levelBadges: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(levels, id: \.id) { level in
                    let selected = level.id == levelID && !showPlugins
                    Button {
                        showPlugins = false
                        levelID = level.id
                    } label: {
                        HStack(spacing: 5) {
                            Text(level.label).font(.label(11))
                            Text("\(inventory?.count(kind: kind, level: level) ?? 0)")
                                .font(.data(10))
                                .monospacedDigit()
                                .opacity(0.8)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .foregroundStyle(selected ? Color.white : Theme.slate)
                        .background(
                            Capsule().fill(selected ? Theme.violet : Theme.cardFill))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(level.label)
                }
                if kind == .skill, let count = inventory?.plugins.count, count > 0 {
                    Button { showPlugins = true } label: {
                        HStack(spacing: 5) {
                            Text("Plugins").font(.label(11))
                            Text("\(count)").font(.data(10)).monospacedDigit().opacity(0.8)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .foregroundStyle(showPlugins ? Color.white : Theme.slate)
                        .background(Capsule().fill(showPlugins ? Theme.violet : Theme.cardFill))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 1)
        }
    }

    // MARK: - List pane

    @ViewBuilder
    private var listPane: some View {
        if showPlugins {
            List(selection: $pluginSelectionID) {
                ForEach(pluginItems) { plugin in
                    PluginRow(plugin: plugin).tag(plugin.id)
                }
            }
            .listStyle(.inset)
            .overlay {
                if pluginItems.isEmpty { emptyState(text: pluginEmptyText) }
            }
        } else {
            List(selection: $selectionID) {
                ForEach(items) { resource in
                    ResourceRow(resource: resource).tag(resource.id)
                }
            }
            .listStyle(.inset)
            .overlay {
                if items.isEmpty { emptyState(text: emptyText) }
            }
        }
    }

    private var emptyText: String {
        if store.skillsState.isLoading && inventory == nil { return "Lecture des ressources…" }
        if !query.isEmpty { return "Aucun résultat pour « \(search) »." }
        return "Aucune ressource de type « \(kind.pluralLabel.lowercased()) » dans \(level.label)."
    }

    private var pluginEmptyText: String {
        if !query.isEmpty { return "Aucun résultat pour « \(search) »." }
        return "Aucun plugin installé."
    }

    private func emptyState(text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.slate)
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
    }

    // MARK: - Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if showPlugins {
            if let plugin = selectedPlugin {
                PluginDetailView(plugin: plugin, levels: levels) { imported in
                    showPlugins = false
                    levelID = imported.level.id
                    selectionID = imported.id
                }
                .id(plugin.id)
            } else {
                placeholder("Sélectionnez un plugin pour voir son contenu.")
            }
        } else if let resource = selectedResource {
            ResourceDetailView(
                resource: resource,
                levels: levels,
                onTransferred: { moved in
                    levelID = moved.level.id
                    selectionID = moved.id
                },
                onDeleted: { selectionID = nil })
            .id(resource.id)
        } else {
            placeholder("Sélectionnez un élément dans la liste.")
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text")
                .font(.system(size: 26))
                .foregroundStyle(Theme.mist)
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.slate)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}

// MARK: - Rows

/// A resource in the list: name, one-line description, relative modified date.
private struct ResourceRow: View {
    let resource: ClaudeResource

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(resource.name)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            if let description = resource.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.slate)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Text(FRFormat.relative(resource.modifiedAt))
                .font(.label(10))
                .foregroundStyle(Theme.mist)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

/// A plugin-provided skill: qualified name, description, version.
private struct PluginRow: View {
    let plugin: PluginResource

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(plugin.qualifiedName)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            if let description = plugin.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.slate)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Text("\(plugin.org) · \(plugin.version)")
                .font(.label(10))
                .foregroundStyle(Theme.mist)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}
