// One transcript turn — see docs/superpowers/specs/2026-09-23-sessions-viewer.md
import SwiftUI
import CockpitShared
import SessionsKit
import UsageKit

/// Renders one `SessionMessage` — a user prompt, an assistant turn with its tool
/// cards, a system line, or a compaction boundary.
///
/// `tool_result` blocks are never rendered on their own: they belong to the card
/// of the `tool_use` they answer, matched on `toolUseId` through `results`.
struct SessionTurnView: View {
    let message: SessionMessage
    /// `toolUseId → tool_result`, built by the detail view over every loaded page.
    let results: [String: ContentBlock]
    /// Time since the previous turn, shown in the assistant footer.
    let elapsed: TimeInterval?
    let depth: Int
    var highlighted = false

    @Environment(CockpitStore.self) private var store
    /// Keyed by block id: a turn can interleave several thinking blocks and each
    /// one opens on its own.
    @State private var expandedThinking: Set<String> = []

    /// True when a line is worth a turn of its own.
    ///
    /// A user line whose blocks are only `tool_result` carries no prompt: its
    /// content is already shown inside the card of the call it answers, and
    /// rendering it would put a blank bubble between every tool call.
    static func isRenderable(_ message: SessionMessage) -> Bool {
        if message.isCompactBoundary { return true }
        if message.role == .user {
            let hasOwnContent = message.blocks.contains { $0.kind != .toolResult }
            return hasOwnContent || message.attachmentCount > 0
        }
        return !message.blocks.isEmpty || message.systemSubtype != nil
    }

    var body: some View {
        Group {
            if message.isCompactBoundary {
                compactDivider
            } else {
                switch message.role {
                case .user: userTurn
                case .assistant: assistantTurn
                case .system: systemLine
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            if highlighted {
                RoundedRectangle(cornerRadius: 2).fill(Theme.accent).frame(width: 3)
            }
        }
    }

    // MARK: - User

    private var userTurn: some View {
        VStack(alignment: .leading, spacing: 8) {
            turnHeader(role: "Vous", icon: "person.crop.circle", tint: Theme.accent)
            ForEach(message.blocks.filter { $0.kind == .text || $0.kind == .image }) { block in
                blockView(block)
            }
            if message.attachmentCount > 0 {
                Label("\(FRFormat.integer(message.attachmentCount)) pièces jointes",
                      systemImage: "paperclip")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.slate)
            }
        }
        .padding(12)
        .background(Theme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Theme.accent.opacity(0.18), lineWidth: 0.5))
    }

    // MARK: - Assistant

    private var assistantTurn: some View {
        VStack(alignment: .leading, spacing: 8) {
            turnHeader(
                role: message.isApiError ? "Assistant — erreur API" : "Assistant",
                icon: message.isApiError ? "exclamationmark.triangle.fill" : "sparkle",
                tint: message.isApiError ? .red : Theme.violet)
            ForEach(message.blocks) { block in
                blockView(block)
            }
            assistantFooter
        }
        .padding(12)
        .background(
            (message.isApiError ? Color.red.opacity(0.08) : Theme.cardFill),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(message.isApiError ? Color.red.opacity(0.5) : Theme.cardStroke, lineWidth: 0.5))
    }

    private var assistantFooter: some View {
        HStack(spacing: 10) {
            Text(SessionsPalette.modelLabel(message.model))
            if message.totalTokens > 0 {
                Text("\(FRFormat.tokens(message.totalTokens)) jetons")
            }
            let cost = SessionsPalette.turnCost(message, pricing: store.pricing)
            if cost > 0 {
                Text(store.money(cost, digits: 4)).foregroundStyle(Theme.blue)
            }
            if let elapsed, elapsed > 0 {
                Text("+\(FRFormat.duration(elapsed))")
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 10))
        .monospacedDigit()
        .foregroundStyle(Theme.mist)
    }

    // MARK: - System

    private var systemLine: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "gearshape")
                .font(.system(size: 10))
                .foregroundStyle(Theme.mist)
            VStack(alignment: .leading, spacing: 2) {
                if let subtype = message.systemSubtype {
                    Text(subtype).font(.label(10)).foregroundStyle(Theme.mist)
                }
                ForEach(message.blocks.filter { $0.kind == .text }) { block in
                    Text(SessionsPalette.oneLine(block.text, limit: 400))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.slate)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private var compactDivider: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Theme.cardStroke).frame(height: 1)
            Label("Contexte compacté", systemImage: "arrow.down.right.and.arrow.up.left")
                .font(.label(10))
                .tracking(0.8)
                .foregroundStyle(Theme.slate)
                .fixedSize()
            Rectangle().fill(Theme.cardStroke).frame(height: 1)
        }
        .padding(.vertical, 8)
    }

    // MARK: - Blocks

    @ViewBuilder
    private func blockView(_ block: ContentBlock) -> some View {
        switch block.kind {
        case .text:
            if !block.text.isEmpty {
                Text(SessionsPalette.markdown(block.text))
                    .font(.system(size: 13))
                    .foregroundStyle(message.isApiError ? Color.red : Theme.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .thinking:
            DisclosureGroup(isExpanded: thinkingBinding(for: block.id)) {
                Text(SessionsPalette.markdown(block.text))
                    .font(.system(size: 12))
                    .italic()
                    .foregroundStyle(Theme.slate)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            } label: {
                Label("Réflexion", systemImage: "brain")
                    .font(.label(11))
                    .foregroundStyle(Theme.violet)
            }
        case .toolUse:
            ToolCallCard(block: block, result: pairedResult(for: block), depth: depth)
        case .toolResult:
            // Shown inside the card of the call it answers.
            EmptyView()
        case .image:
            Label("Image (\(block.imageMediaType ?? "type inconnu"))", systemImage: "photo")
                .font(.system(size: 11))
                .foregroundStyle(Theme.slate)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Theme.cardFill))
        }
    }

    private func thinkingBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { expandedThinking.contains(id) },
            set: { isOpen in
                if isOpen { expandedThinking.insert(id) } else { expandedThinking.remove(id) }
            })
    }

    private func pairedResult(for block: ContentBlock) -> ContentBlock? {
        guard let id = block.toolUseId else { return nil }
        return results[id]
    }

    private func turnHeader(role: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(tint)
            Text(role).font(.label(11)).tracking(0.6).foregroundStyle(tint)
            Spacer(minLength: 8)
            Text(FRFormat.time(message.timestamp))
                .font(.data(10))
                .foregroundStyle(Theme.mist)
        }
    }
}
