import SwiftUI

struct MainWindowView: View {
    static let windowID = "main"
    @Environment(CockpitStore.self) private var store
    @EnvironmentObject private var updater: UpdaterController
    @AppStorage(SettingsKey.mainSection) private var sectionRaw: String = CockpitSection.overview.rawValue

    private var selection: Binding<CockpitSection?> {
        Binding(
            get: { CockpitSection(rawValue: sectionRaw) ?? .overview },
            set: { sectionRaw = ($0 ?? .overview).rawValue })
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                Section("Tableau de bord") {
                    row(.overview); row(.usage); row(.sessions); row(.quotas); row(.rtk)
                }
                Section("Atelier") {
                    row(.skills); row(.agents); row(.commands)
                }
                Section {
                    row(.settings)
                }
            }
            .modifier(SidebarStyle())
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            detail(for: selection.wrappedValue ?? .overview)
                .frame(minWidth: 860, minHeight: 640)
                .background(Theme.background)
        }
        .navigationTitle("Claude Cockpit")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await store.refreshAll() }
                } label: {
                    Label("Rafraîchir", systemImage: "arrow.clockwise")
                }
                .help("Rafraîchir toutes les sources")
            }
        }
        .overlay(alignment: .bottom) { NoticeToast() }
        .task {
            await SnapshotRunner.runIfRequested(store: store, updater: updater) { sectionRaw = $0.rawValue }
        }
    }

    private func row(_ section: CockpitSection) -> some View {
        NavigationLink(value: section) {
            Label(section.title, systemImage: section.icon)
        }
    }

    @ViewBuilder
    private func detail(for section: CockpitSection) -> some View {
        switch section {
        case .overview: OverviewView()
        case .usage: UsageView()
        case .sessions: SessionsView()
        case .quotas: QuotasView()
        case .rtk: RTKView()
        case .skills: ResourcesView(kind: .skill)
        case .agents: ResourcesView(kind: .agent)
        case .commands: ResourcesView(kind: .command)
        case .settings: SettingsView()
        }
    }
}

/// The vibrant sidebar material cannot be rendered by in-process snapshots, so
/// the snapshot mode falls back to a flat list on a solid background.
private struct SidebarStyle: ViewModifier {
    func body(content: Content) -> some View {
        if SnapshotRunner.requestedDirectory != nil {
            content.listStyle(.plain).scrollContentBackground(.hidden).background(Theme.panel)
        } else {
            content.listStyle(.sidebar)
        }
    }
}

/// Transient bottom toast for `store.notice`.
struct NoticeToast: View {
    @Environment(CockpitStore.self) private var store
    var body: some View {
        if let notice = store.notice {
            Text(notice)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: notice) {
                    try? await Task.sleep(for: .seconds(4))
                    if store.notice == notice { store.notice = nil }
                }
        }
    }
}
