import SwiftUI
import AppKit

/// Design tokens shared by the menu-bar panel and the main window.
/// Dark-first, with adaptive colours so light mode stays readable.
enum Theme {
    // MARK: Layout
    static let panelWidth: CGFloat = 340
    static let cardRadius: CGFloat = 14
    static let tileRadius: CGFloat = 12

    // MARK: Colours
    /// Claude's warm terracotta — quotas, primary emphasis.
    static let accent = adaptive(light: 0xC9603F, dark: 0xD97757)
    static let accentSoft = adaptive(light: 0xF0A080, dark: 0xF0A080)
    /// Emerald — RTK savings. Never paired with red/orange for RTK.
    static let emerald = adaptive(light: 0x12B886, dark: 0x1FD79B)
    /// Blue — local usage (tokens, cost).
    static let blue = adaptive(light: 0x2A78D6, dark: 0x4D8CE0)
    /// Violet — skills, agents, commands.
    static let violet = adaptive(light: 0x7A5AF8, dark: 0x9B84FF)

    static let background = adaptive(light: 0xF7F7F5, dark: 0x0E1013)
    static let panel = adaptive(light: 0xFCFCFB, dark: 0x171A1F)
    static let cardFill = Color.primary.opacity(0.06)
    static let cardStroke = Color.primary.opacity(0.07)
    static let track = Color.primary.opacity(0.12)
    static let ink = adaptive(light: 0x16191D, dark: 0xECEFF2)
    static let slate = adaptive(light: 0x5B6470, dark: 0x9AA3AE)
    static let mist = adaptive(light: 0x9AA3AE, dark: 0x5B6470)

    /// Green while comfortable, orange when it gets tight, red when over (quotas).
    static func tone(used: Double) -> Color {
        used >= 100 ? .red : (used >= 80 ? .orange : .green)
    }
    /// Only a meaningful projection may darken the tone; otherwise judge on usage alone.
    static func tone(used: Double, landing: Double?) -> Color {
        guard let landing, landing > 100 else { return tone(used: used) }
        return used >= 80 ? .red : .orange
    }

    /// Emerald intensity for an RTK savings percentage (0…100). Low-signal
    /// commands read as neutral mist, never judged.
    static func savingsIntensity(_ pct: Double) -> Color {
        let t = min(1, max(0, pct / 100))
        if t < 0.35 { return mist }
        return emerald.opacity(0.55 + (t - 0.35) / 0.65 * 0.45)
    }

    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: 1)
    }
}

// MARK: - Typography

extension Font {
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
    static func label(_ size: CGFloat = 11, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight)
    }
    static func data(_ size: CGFloat = 12) -> Font {
        .system(size: size, design: .monospaced)
    }
}

// MARK: - Containers

struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .stroke(Theme.cardStroke, lineWidth: 0.5))
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }

    /// Full-width section container used in the main window.
    func panelStyle() -> some View {
        padding(20)
            .background(Theme.panel)
            .overlay(RoundedRectangle(cornerRadius: Theme.tileRadius).stroke(Theme.cardStroke, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.tileRadius))
    }
}

/// Uppercase tracked label above a value.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.label())
            .tracking(1.2)
            .foregroundStyle(Theme.slate)
    }
}

/// KPI tile: label, big value, optional footnote and tint.
struct StatTile: View {
    let label: String
    let value: String
    var note: String? = nil
    var tint: Color = Theme.ink
    var icon: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                }
                SectionLabel(text: label)
            }
            Text(value)
                .font(.display(26))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let note {
                Text(note).font(.system(size: 11)).foregroundStyle(Theme.slate).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .card()
    }
}

/// Segmented capsule bar with quarter ticks (quota gauges).
struct SegmentedBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(color)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
                HStack(spacing: 0) {
                    ForEach(1..<4) { i in
                        Spacer()
                        Rectangle().fill(Color.black.opacity(0.25)).frame(width: 1)
                            .opacity(Double(i) / 4 < fraction ? 1 : 0)
                    }
                    Spacer()
                }
            }
        }
        .frame(height: 8)
    }
}

/// Collapsible card with a chevron header.
struct DisclosureCard<Content: View>: View {
    let title: String
    let icon: String
    let iconColor: Color
    @Binding var expanded: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(iconColor)
                        .frame(width: 22)
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(spacing: 0) { content }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
        .card()
    }
}

/// "Libellé ……… valeur" row.
struct InfoRow: View {
    let label: String
    let value: String
    var tint: Color? = nil
    var note: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(value)
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(tint ?? .primary)
                    .multilineTextAlignment(.trailing)
            }
            if let note {
                Text(note).font(.system(size: 11)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
    }
}

/// Settings-list row with a leading SF Symbol.
struct ActionRow<Trailing: View>: View {
    let icon: String
    let iconColor: Color
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .medium))
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 40)
    }
}

extension ActionRow where Trailing == EmptyView {
    init(icon: String, iconColor: Color, title: String, subtitle: String? = nil) {
        self.init(icon: icon, iconColor: iconColor, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Inline banner for a failing data source.
struct SourceBanner: View {
    enum Kind { case info, warning, error }
    let kind: Kind
    let message: String
    var action: (() -> Void)? = nil
    var actionTitle: String = "Réessayer"

    private var tint: Color {
        switch kind {
        case .info: Theme.blue
        case .warning: .orange
        case .error: .red
        }
    }
    private var icon: String {
        switch kind {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(message).font(.system(size: 12)).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let action {
                Button(actionTitle, action: action).controlSize(.small)
            }
        }
        .padding(12)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
