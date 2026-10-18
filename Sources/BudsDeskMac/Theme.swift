import SwiftUI

/// The palette, and the two rules that keep it honest.
///
/// **Rule 1 — fill and accent are different jobs.** `selection` is a fill and never a glyph;
/// `accent` is a glyph, a stroke or a glow and never a fill. That division is what lets the
/// selected state survive greyscale, because the fill is not the only signal.
///
/// **Rule 2 — a selected control says so three ways.** A fill, a hairline stroke, and a change in
/// height and weight. Colour alone is not a state: it is invisible to anyone who cannot see it,
/// and to anyone reading the screen instead of the window.
enum Theme {

    // MARK: Colours

    /// Glyphs, strokes and glows. Always drawn *on* a surface, never used to fill one.
    static let accent = Color(red: 0.35, green: 0.66, blue: 1.00)
    /// The fill behind a selected control, and nothing else.
    static let selection = Color.white.opacity(0.16)
    /// The hairline around a selected control. This is what carries the selection when the fill
    /// is nearly invisible against the surface behind it — on the panel's top gradient the fill
    /// alone measures 2.96:1, which is below the 3:1 that a non-text indicator needs.
    static let selectionStroke = Color.white.opacity(0.38)

    static let window = Color(red: 0.09, green: 0.10, blue: 0.12)
    static let card = Color.white.opacity(0.045)
    static let cardStroke = Color.white.opacity(0.08)
    static let primaryText = Color.white.opacity(0.94)
    static let secondaryText = Color.white.opacity(0.66)
    static let tertiaryText = Color.white.opacity(0.50)

    static let good = Color(red: 0.42, green: 0.82, blue: 0.55)
    static let warning = Color(red: 0.98, green: 0.76, blue: 0.36)
    static let pending = Color(red: 0.98, green: 0.76, blue: 0.36)

    // MARK: Metrics

    static let selectedHeight: CGFloat = 36
    static let unselectedHeight: CGFloat = 30
    static let corner: CGFloat = 10
}

/// Whether the system asks for less movement. Every animation in this app is decorative, so
/// honouring this costs nothing but must not be forgotten.
struct Motion {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func animation(_ animation: Animation = .easeInOut(duration: 0.18)) -> Animation? {
        reduceMotion ? nil : animation
    }
}

/// The card every group of controls sits in.
struct Card<Content: View>: View {
    let title: String
    var subtitle: String?
    /// Set when a capability is not confirmed for this model, so the card can say so instead of
    /// looking broken. A control that silently does nothing is the failure this app is built to
    /// avoid, so it is labelled rather than hidden or disabled without explanation.
    var note: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
            if let note {
                Label(note, systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.corner))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(Theme.cardStroke, lineWidth: 1))
    }
}

/// A selectable pill — the one interactive primitive in this app.
///
/// The selection is carried by four things at once: the fill, the stroke, the height, and the
/// font weight. Take any three away in greyscale and the fourth still says which one is chosen.
struct Pill: View {
    let label: String
    var symbol: String?
    var detail: String?
    let isSelected: Bool
    var isPending: Bool = false
    /// False when the device has the capability but no *verified* write path for it. The pill is
    /// still drawn and still shows the reported value — it simply cannot be pressed. Hiding it
    /// would erase the reading; enabling it would be a lie.
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var isHovering = false
    private var motion = Motion()

    /// Explicit rather than the memberwise one, which the private state above makes private.
    init(label: String, symbol: String? = nil, detail: String? = nil,
         isSelected: Bool, isPending: Bool = false, isEnabled: Bool = true,
         action: @escaping () -> Void) {
        self.label = label
        self.symbol = symbol
        self.detail = detail
        self.isSelected = isSelected
        self.isPending = isPending
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isSelected ? Theme.accent : Theme.secondaryText)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(Theme.primaryText)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.tertiaryText)
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: isSelected ? Theme.selectedHeight : Theme.unselectedHeight)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Theme.corner)
                    .fill(isSelected ? Theme.selection
                                     : (isHovering && isEnabled ? Color.white.opacity(0.06)
                                                                : Color.white.opacity(0.02)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.corner)
                    .stroke(isSelected ? Theme.selectionStroke : Theme.cardStroke,
                            lineWidth: isSelected ? 1.5 : 1)
            )
            .overlay(alignment: .topTrailing) {
                if isPending {
                    Image(systemName: "clock")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.pending)
                        .padding(5)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.corner))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.62)
        .onHover { isHovering = isEnabled && $0 }
        .animation(motion.animation(), value: isSelected)
        .animation(motion.animation(), value: isPending)
        // Accessibility: the label is the name, the selection is the value, and the selected
        // trait is set so a screen reader announces which one is chosen rather than making the
        // user infer it from the name alone.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label + (detail.map { ", \($0)" } ?? ""))
        .accessibilityValue(isSelected ? "selected" : "not selected")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(isEnabled ? "" : "Not available for this model yet.")
    }
}
