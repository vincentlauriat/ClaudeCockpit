// Tool call card — see docs/superpowers/specs/2026-09-23-sessions-viewer.md
import SwiftUI
import CockpitShared
import SessionsKit
import UsageKit

/// One `tool_use` block with its paired `tool_result`, collapsed by default.
///
/// The pair is resolved by the detail view, which keeps a `toolUseId → result`
/// index over every loaded page: a call and its result sit on two different
/// transcript lines, so paging can load one without the other. A card whose
/// result has not been paged in yet says so instead of pretending the call
/// returned nothing.
struct ToolCallCard: View {
    let block: ContentBlock
    let result: ContentBlock?
    /// 0 for the session's own turns, +1 for each sub-agent transcript opened inside.
    let depth: Int

    @Environment(CockpitStore.self) private var store

    @State private var expanded = false
    @State private var inputExpanded = true
    @State private var outputExpanded = true
    @State private var showFullOutput = false
    @State private var subagentExpanded = false
    @State private var subagentMessages: [SessionMessage] = []
    @State private var subagentLoading = false

    /// Sub-agents may themselves call sub-agents; two levels is all the inline
    /// renderer opens, deeper transcripts stay one click away in their own row.
    private static let maxDepth = 2

    private var isError: Bool { result?.isError ?? false }
    private var toolName: String { block.toolName ?? "Outil" }
    private var tag: String? {
        SessionsPalette.argumentTag(toolName: block.toolName, input: block.text, fileEdit: block.fileEdit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    inputSection
                    outputSection
                    subagentSection
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isError ? Color.red.opacity(0.65) : Theme.cardStroke, lineWidth: isError ? 1 : 0.5))
    }

    // MARK: - Header

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.mist)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Image(systemName: SessionsPalette.icon(forTool: block.toolName))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SessionsPalette.tint(forTool: block.toolName))
                    .frame(width: 18)
                Text(toolName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                if let tag {
                    Text(tag)
                        .font(.data(11))
                        .foregroundStyle(Theme.slate)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if let edit = block.fileEdit {
                    Text(SessionsPalette.editCounters(edit))
                        .font(.data(10))
                        .monospacedDigit()
                        .foregroundStyle(Theme.emerald)
                }
                if isError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .accessibilityLabel("Cet appel a échoué")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(toolName). \(tag ?? "")")
    }

    // MARK: - Input

    @ViewBuilder
    private var inputSection: some View {
        DisclosureGroup(isExpanded: $inputExpanded) {
            if let edit = block.fileEdit {
                DiffBox(edit: edit)
            } else {
                MonospacedBox(text: block.text.isEmpty ? "(aucun argument)" : block.text)
            }
        } label: {
            sectionLabel("Entrée", icon: "arrow.right.circle")
        }
    }

    // MARK: - Output

    @ViewBuilder
    private var outputSection: some View {
        if let result {
            DisclosureGroup(isExpanded: $outputExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    MonospacedBox(text: shownOutput(result.text), tint: result.isError ? .red : Theme.ink)
                    if isCut(result.text) {
                        Button("Afficher tout (\(FRFormat.integer(result.text.count)) caractères)") {
                            showFullOutput = true
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                    }
                }
            } label: {
                sectionLabel(result.isError ? "Sortie — erreur" : "Sortie", icon: "arrow.left.circle")
            }
        } else {
            Label("Résultat non chargé — il arrive avec la page suivante du transcript.",
                  systemImage: "clock.arrow.circlepath")
                .font(.system(size: 11))
                .foregroundStyle(Theme.slate)
        }
    }

    private func isCut(_ text: String) -> Bool {
        !showFullOutput && text.count > SessionsPalette.outputCap
    }

    private func shownOutput(_ text: String) -> String {
        guard isCut(text) else { return text }
        return String(text.prefix(SessionsPalette.outputCap)) + "\n… [coupé]"
    }

    // MARK: - Sub-agent

    @ViewBuilder
    private var subagentSection: some View {
        if let agentId = block.subagentId {
            if depth >= Self.maxDepth {
                Label("Sous-agent imbriqué trop profondément — ouvrez-le depuis la liste des sessions.",
                      systemImage: "arrow.turn.down.right")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.slate)
            } else {
                DisclosureGroup(isExpanded: $subagentExpanded) {
                    subagentBody
                } label: {
                    sectionLabel("Ouvrir le sous-agent", icon: "person.2.fill")
                }
                .onChange(of: subagentExpanded) { _, isOpen in
                    guard isOpen, subagentMessages.isEmpty, !subagentLoading else { return }
                    Task { await loadSubagent(agentId) }
                }
            }
        }
    }

    @ViewBuilder
    private var subagentBody: some View {
        if subagentLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Lecture du transcript du sous-agent…")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.slate)
            }
            .padding(.vertical, 6)
        } else if subagentMessages.isEmpty {
            Text("Transcript du sous-agent introuvable dans l'index.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.slate)
                .padding(.vertical, 6)
        } else {
            // AnyView breaks the mutual recursion between this card and the turn
            // renderer: without it the two opaque body types are defined in terms
            // of each other and the file will not compile.
            AnyView(SubagentTranscript(messages: subagentMessages, depth: depth + 1))
        }
    }

    private func loadSubagent(_ agentId: String) async {
        subagentLoading = true
        let loaded = await store.subagentMessages(agentId)
        subagentMessages = loaded
        subagentLoading = false
    }

    // MARK: - Bits

    private func sectionLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10))
            Text(title).font(.label(11)).tracking(0.6)
        }
        .foregroundStyle(Theme.slate)
    }
}

/// The sub-agent's own turns, inset so the nesting reads at a glance.
private struct SubagentTranscript: View {
    let messages: [SessionMessage]
    let depth: Int

    /// The sub-agent transcript comes whole, so its pairs are all resolvable here.
    private var results: [String: ContentBlock] {
        var map: [String: ContentBlock] = [:]
        for message in messages {
            for block in message.blocks where block.kind == .toolResult {
                if let id = block.toolUseId { map[id] = block }
            }
        }
        return map
    }

    var body: some View {
        let index = results
        VStack(alignment: .leading, spacing: 10) {
            ForEach(messages.filter(SessionTurnView.isRenderable)) { message in
                SessionTurnView(message: message, results: index, elapsed: nil, depth: depth)
            }
        }
        .padding(.leading, 12)
        .padding(.vertical, 6)
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.violet.opacity(0.4)).frame(width: 2)
        }
    }
}

/// Coloured diff of a file edit: removed lines in red, added lines in green.
private struct DiffBox: View {
    let edit: FileEdit

    var body: some View {
        let lines = SessionsPalette.diffLines(for: edit)
        VStack(alignment: .leading, spacing: 4) {
            Text(UsagePath.shorten(edit.path))
                .font(.data(11))
                .foregroundStyle(Theme.slate)
                .lineLimit(1)
                .truncationMode(.head)
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        HStack(alignment: .top, spacing: 6) {
                            Text(line.kind == .added ? "+" : "\u{2212}")
                                .font(.data(11))
                                .foregroundStyle(line.kind == .added ? Theme.emerald : .red)
                            Text(line.text.isEmpty ? " " : line.text)
                                .font(.data(11))
                                .foregroundStyle(line.kind == .added ? Theme.emerald : .red)
                                .textSelection(.enabled)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            (line.kind == .added ? Theme.emerald : Color.red).opacity(0.10))
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 320)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            if lines.count >= SessionsPalette.diffLineCap {
                Text("Diff tronqué à \(FRFormat.integer(SessionsPalette.diffLineCap)) lignes.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.mist)
            }
        }
    }
}
