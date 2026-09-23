// Sessions section container — see docs/superpowers/specs/2026-09-23-sessions-viewer.md
import SwiftUI
import CockpitShared
import SessionsKit

/// The Sessions section: a browser over the whole transcript archive, plus the two
/// feeds derived from it. The three tabs share one index; none of them re-reads the
/// archive on its own.
struct SessionsView: View {
    @Environment(CockpitStore.self) private var store
    @AppStorage("sessions.tab") private var tabRaw: String = SessionsTab.browser.rawValue

    enum SessionsTab: String, CaseIterable, Identifiable {
        case browser, activity, edits
        var id: String { rawValue }
        var title: String {
            switch self {
            case .browser: "Sessions"
            case .activity: "Activité"
            case .edits: "Fichiers modifiés"
            }
        }
    }

    private var tab: Binding<SessionsTab> {
        Binding(get: { SessionsTab(rawValue: tabRaw) ?? .browser }, set: { tabRaw = $0.rawValue })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            content
        }
        .background(Theme.background)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("", selection: tab) {
                ForEach(SessionsTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 380)
            Spacer()
            IndexStatusBadge()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        switch tab.wrappedValue {
        case .browser: SessionsBrowserView()
        case .activity: SessionsActivityView()
        case .edits: RecentEditsView()
        }
    }
}

/// Indexing state, shown in every tab: the first index of a large archive takes a
/// while and silence there would read as a broken section.
struct IndexStatusBadge: View {
    @Environment(CockpitStore.self) private var store

    var body: some View {
        let progress = store.sessionIndex
        HStack(spacing: 8) {
            if progress.isRunning {
                ProgressView().controlSize(.small)
                Text("Indexation \(progress.filesDone)/\(progress.filesTotal)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else if let message = store.sessionsState.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            } else if let last = progress.lastRun {
                Text("Index à jour · \(FRFormat.relative(last, now: Date()))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
