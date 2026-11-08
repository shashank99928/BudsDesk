import SwiftUI

/// The four places the window can be.
///
/// The window used to be one long column: battery, noise, equalizer, BassWave, gestures,
/// multi-connect, details and the log, in that order, whether or not any of it was what a person
/// had opened the window to change. Sections put the two controls someone adjusts most — the
/// noise mode and the equalizer — one press from the top, and leave the reference material where
/// reference material belongs.
///
/// The division is by job rather than by protocol service:
///
/// - **Status** — what the hardware is doing now: charge, wear, noise mode.
/// - **Sound** — the controls that shape what comes out of it: equalizer and BassWave.
/// - **Controls** — what a touch does, and which devices share the buds.
/// - **Details** — what the hardware reports, and what the app has done.
///
/// Nothing moved between cards and no card gained or lost a control; the same `Session` and the
/// same registry still decide what is drawn and what can be written.
enum WindowSection: String, CaseIterable, Identifiable {
    case status
    case sound
    case controls
    case details

    var id: String { rawValue }

    var title: String {
        switch self {
        case .status: return "Status"
        case .sound: return "Sound"
        case .controls: return "Controls"
        case .details: return "Details"
        }
    }

    var symbol: String {
        switch self {
        case .status: return "battery.75"
        case .sound: return "waveform"
        case .controls: return "hand.tap"
        case .details: return "info.circle"
        }
    }
}

/// The window's navigation: a notch island, not a toolbar.
///
/// It floats over the window's ground with a hairline and a shadow so it reads as chrome laid on
/// the surface rather than another card in the column. The selected pill moves between tabs on a
/// spring, which is the one animation in the app that carries meaning: it says the four tabs are
/// one control, and the one you left is the one you arrived from.
///
/// Every tab is still a button, and selection is still carried three ways — fill, hairline and
/// weight — because the palette rule does not stop at the cards (see `Theme`).
struct NotchTabBar: View {
    @Binding var section: WindowSection

    @Namespace private var selection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            // Equal widths, computed rather than left to the stack: four flexible children with
            // different labels are not four equal children, and a pill that stops 4 points from
            // one edge and touches the other reads as a layout bug.
            let inset: CGFloat = 4
            let spacing: CGFloat = 2
            let count = CGFloat(WindowSection.allCases.count)
            let width = (proxy.size.width - inset * 2 - spacing * (count - 1)) / count

            HStack(spacing: spacing) {
                ForEach(WindowSection.allCases) { item in
                    NotchTab(item: item,
                             isSelected: section == item,
                             selection: selection,
                             action: { select(item) })
                        .frame(width: width)
                }
            }
            .padding(inset)
        }
        .frame(height: Theme.notchTabHeight + 8)
        .background {
            RoundedRectangle(cornerRadius: Theme.notchCorner)
                .fill(Theme.notch)
                .shadow(color: .black.opacity(0.32), radius: 12, y: 4)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.notchCorner)
                .stroke(Theme.notchStroke, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Window sections")
    }

    private func select(_ item: WindowSection) {
        guard item != section else { return }
        withAnimation(Theme.section(reduceMotion)) {
            section = item
        }
    }
}

/// One tab. Equal widths, so the pill's travel is a straight line and the labels do not shuffle
/// sideways when the selection changes.
private struct NotchTab: View {
    let item: WindowSection
    let isSelected: Bool
    let selection: Namespace.ID
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: item.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.secondaryText)
                Text(item.title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Theme.primaryText : Theme.secondaryText)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .frame(height: Theme.notchTabHeight)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: Theme.notchTabCorner)
                        .fill(Theme.notchSelection)
                        .overlay {
                            RoundedRectangle(cornerRadius: Theme.notchTabCorner)
                                .stroke(Theme.notchSelectionStroke, lineWidth: 1)
                        }
                        .matchedGeometryEffect(id: "section-pill", in: selection)
                } else if isHovering {
                    RoundedRectangle(cornerRadius: Theme.notchTabCorner)
                        .fill(Color.white.opacity(0.05))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.notchTabCorner))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(Theme.motion(reduceMotion), value: isHovering)
        .accessibilityLabel(item.title)
        .accessibilityValue(isSelected ? "selected" : "not selected")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
