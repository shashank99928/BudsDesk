import SwiftUI
import BudsCore

/// The window: every control, grouped, each one drawn because the capability registry says the
/// model has it.
///
/// The views here are deliberately dumb. They read a `Session` and a `DeviceProfile` and they call
/// three closures. No view decides whether a write is allowed — the session does that, from the
/// registry — and no view decides what a value means — the protocol does that. A view that made
/// either decision could disagree with the test suite about it, and then there would be two
/// answers.
struct DeviceWindow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                StatusHeader(model: model)

                if !model.hasRegistry {
                    // A broken install. This is the one case that means the registry could not be
                    // read, and it used to be drawn for "no earbuds found" as well — which told a
                    // person on their first launch that the app was broken when it was not.
                    RegistryMissingCard(model: model)
                } else if let profile = model.profile {
                    if model.isReady, let session = model.session {
                        BatteryCard(session: session)
                        if profile.offers(.noiseControl) { NoiseCard(model: model, session: session, profile: profile) }
                        if profile.offers(.equalizer) { EqualizerCard(model: model, session: session, profile: profile) }
                        if profile.offers(.bassWave) { BassWaveCard(model: model, session: session, profile: profile) }
                        if profile.offers(.gestures) { GesturesCard(model: model, session: session, profile: profile) }
                        if profile.offers(.multipoint) { LinkedDevicesCard(session: session, profile: profile) }
                        DetailsCard(session: session)
                    } else {
                        WaitingCard(model: model, profile: profile)
                    }
                } else {
                    NoEarbudsCard(model: model)
                }

                ActivityCard(model: model)
                ProvenanceFooter(model: model)
            }
            .padding(16)
        }
        .background(Theme.window)
        .frame(minWidth: 400, idealWidth: 440, minHeight: 460)
    }
}

// MARK: - Header

/// EQ preset icons.
///
/// Kept here rather than in `BudsCore` because an SF Symbol name is a *view* detail: the protocol
/// core has no opinion about how a preset looks, and putting a symbol name in the portable layer
/// would drag a macOS vocabulary into a file meant to compile on Windows and Linux.
///
/// `Tools/check-symbols.swift` scans this file too, so a name the OS does not know fails a build
/// rather than rendering as a blank.
extension EQPreset {
    var symbol: String {
        switch self {
        case .balanced: return "equal"
        case .clearVocals: return "waveform"
        case .bass: return "speaker.wave.3"
        case .custom: return "slider.horizontal.3"
        }
    }
}

private struct StatusHeader: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.device?.name ?? "BudsDesk")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Text(model.status)
                    .font(.system(size: 11))
                    .foregroundStyle(model.problem == nil ? Theme.secondaryText : Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if model.isReady || model.isOpening {
                Button("Disconnect") { model.disconnect() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Color.white.opacity(0.06), in: Capsule())
                    .accessibilityLabel("Disconnect from the earbuds")
            }
        }
    }
}

/// The device is present but the link is not up. This is the state a person most needs words for,
/// so it says what is happening and what to do rather than drawing empty boxes.
private struct WaitingCard: View {
    @ObservedObject var model: AppModel
    let profile: DeviceProfile
    /// True while the app is drawing itself off-screen. See `Render`.
    @Environment(\.isRenderingSnapshot) private var isRenderingSnapshot

    var body: some View {
        Card(title: head, subtitle: detail) {
            if isRenderingSnapshot {
                // An indeterminate bar animates, so a still of it is a still of whichever moment
                // the snap caught — a different picture every time. The drawing gets the bar's
                // shape at rest instead; the layout is what the picture is for.
                Capsule().fill(Theme.cardStroke).frame(height: 4)
            } else {
                ProgressView().controlSize(.small).progressViewStyle(.linear)
            }
        }
    }

    private var head: String {
        model.isOpening ? "Opening the control channel…" : "Waiting for a link"
    }

    private var detail: String {
        if model.isOpening {
            return "The earbuds are paired. The control channel is exclusive: if the phone app "
                 + "or another copy of BudsDesk is holding it, this will not open."
        }
        if model.problem != nil { return model.problem ?? "" }
        return "The earbuds are paired but not answering yet. They may be in the case, asleep, or "
             + "out of range — a sleeping pair is the usual reason, and they will connect on "
             + "their own once they wake."
    }
}

/// The registry loaded and nothing paired with this Mac advertises the control service: an ordinary
/// first launch, or earbuds that are out of range.
///
/// Deliberately not the same card as "no registry". A window that says the registry could not be
/// read when in fact nothing is paired tells a person their install is broken on the first run —
/// which is exactly what this window did until the `away` golden caught it.
private struct NoEarbudsCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Card(title: "No earbuds found yet",
             subtitle: "Nothing paired with this Mac advertises the control service these earbuds "
                     + "share.") {
            Text("Pair them in System Settings → Bluetooth. They connect as audio devices without "
                 + "BudsDesk; the settings macOS does not expose are what this app adds. A pair "
                 + "asleep in the case still counts as paired — this line is about Bluetooth's "
                 + "records, not about the buds being awake.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct RegistryMissingCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Card(title: "No capability registry",
             subtitle: model.problem ?? "The registry could not be read, so nothing can be offered.") {
            Text("A registry is what says which controls a model has and which have been measured. "
                 + "Without one, this app would have to guess — which it will not do.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Battery and wear

private struct BatteryCard: View {
    let session: Session

    var body: some View {
        Card(title: "Battery", subtitle: subtitle) {
            HStack(spacing: 10) {
                chip("Left", session.battery.left, session.placement.left)
                chip("Right", session.battery.right, session.placement.right)
                chip("Case", session.battery.enclosure, session.placement.enclosure)
            }
        }
    }

    private var subtitle: String {
        if session.battery.left == nil, session.battery.right == nil {
            return "The buds have not reported a charge yet."
        }
        if session.isCaseReported, session.battery.enclosure == nil {
            return "The case is present but has not reported a charge — on this channel it never "
                 + "does, even while the wear report names it on every poll."
        }
        return "Read from the device and refreshed on every poll. A bud in the case drops out of "
             + "the report rather than reporting as empty."
    }

    private func chip(_ title: String, _ level: Int?, _ place: BudsProtocol.BudPlacement?) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.tertiaryText)
            Text(level.map { "\($0)%" } ?? "—")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(level == nil ? Theme.tertiaryText : Theme.primaryText)
                .monospacedDigit()
            Text(placeLabel(place))
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) battery")
        .accessibilityValue(level.map { "\($0) percent, \(placeLabel(place))" } ?? "not reported")
    }

    private func placeLabel(_ place: BudsProtocol.BudPlacement?) -> String {
        switch place {
        case .inEar: return "in ear"
        case .inCase: return "in case"
        case .outOfCase: return "out of case"
        case .notPresent: return "not present"
        case nil: return "unknown"
        }
    }
}

// MARK: - Noise control

private struct NoiseCard: View {
    @ObservedObject var model: AppModel
    let session: Session
    let profile: DeviceProfile

    var body: some View {
        Card(title: "Noise control", subtitle: subtitle, note: note) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(profile.noiseModes) { mode in
                    Pill(label: mode.label,
                         symbol: mode.symbol,
                         detail: mode == .noiseCancellation ? "Cancellation at the last level used" : nil,
                         isSelected: session.mode == mode,
                         isPending: session.unconfirmedWrites.contains(.noiseControl),
                         isEnabled: profile.canWrite(.noiseControl)) {
                        model.set(mode: mode)
                    }
                }
                if !profile.ancLevels.isEmpty {
                    Text("Cancellation level")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.tertiaryText)
                        .padding(.top, 2)
                    ForEach(profile.ancLevels) { level in
                        Pill(label: level.label,
                             isSelected: session.mode == .noiseCancellation && session.ancLevel == level,
                             isPending: session.unconfirmedWrites.contains(.noiseControl),
                             isEnabled: profile.canWrite(.noiseControl)) {
                            model.set(ancLevel: level)
                        }
                    }
                }
            }
        }
    }

    private var subtitle: String {
        guard let mode = session.mode else {
            return "The mode has not been reported yet. It is polled rather than pushed: the "
                 + "notification that carries it is lossy on this hardware."
        }
        guard mode == .noiseCancellation, let level = session.ancLevel else { return mode.label }
        return "\(mode.label) · \(level.label)"
    }

    private var note: String? {
        profile.canWrite(.noiseControl)
            ? "Each mode is one 16-bit mask, set and read back one at a time. A change made on the "
              + "phone shows up here on the next poll."
            : "This model has no measured write path for noise control, so the reported mode is "
              + "shown and cannot be changed here."
    }
}

// MARK: - Equalizer

private struct EqualizerCard: View {
    @ObservedObject var model: AppModel
    let session: Session
    let profile: DeviceProfile

    var body: some View {
        Card(title: "Equalizer", subtitle: subtitle, note: note) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(profile.eqPresets) { preset in
                    Pill(label: preset.label,
                         symbol: preset.symbol,
                         detail: preset == .custom ? customDetail : nil,
                         isSelected: session.eqPreset == preset,
                         isPending: session.unconfirmedWrites.contains(.equalizer),
                         isEnabled: profile.canWrite(.equalizer) && isEnabled(preset)) {
                        model.set(eqPreset: preset)
                    }
                }
            }
        }
    }

    /// The custom slot is a real preset value that the firmware will happily store, and selecting
    /// it with no saved profile leaves the phone's own picker showing nothing.
    private func isEnabled(_ preset: EQPreset) -> Bool {
        preset != .custom || session.hasCustomEQProfile == true
    }

    private var customDetail: String? {
        switch session.hasCustomEQProfile {
        case true: return "A saved profile exists"
        case false: return "No saved profile yet"
        case nil: return "Reading…"
        }
    }

    private var subtitle: String {
        session.eqPreset.map { "Preset: \($0.label)" } ?? "The preset has not been reported yet."
    }

    private var note: String? {
        var lines: [String] = []
        if !profile.canWrite(.equalizer) {
            lines.append("This model has no measured write path for the equalizer.")
        }
        lines.append("Writing a custom profile is a file transfer and is out of scope, like "
                     + "firmware updates — so the custom slot can be selected here if one exists, "
                     + "but not created.")
        return lines.joined(separator: " ")
    }
}

// MARK: - BassWave

private struct BassWaveCard: View {
    @ObservedObject var model: AppModel
    let session: Session
    let profile: DeviceProfile

    var body: some View {
        Card(title: "BassWave", subtitle: subtitle, note: note) {
            HStack(spacing: 10) {
                stepButton("minus", enabled: canStep(-1)) { step(-1) }
                Text(levelLabel)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.primaryText)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("BassWave level")
                    .accessibilityValue(levelLabel)
                stepButton("plus", enabled: canStep(1)) { step(1) }
            }
            if let bounds = session.bassWaveBounds {
                Text("The earbuds report a range of \(bounds.lowerBound) to \(bounds.upperBound). "
                     + "The bounds travel with the write, so a model with a different range needs "
                     + "no code change.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }

    private var levelLabel: String {
        guard let level = session.bassWave else { return "—" }
        return level > 0 ? "+\(level)" : "\(level)"
    }

    private var subtitle: String {
        guard session.bassWaveBounds != nil else {
            return "The level has not been reported yet. The earbuds state their own range in the "
                 + "same reply, so nothing is written until they have."
        }
        return "Selected: \(levelLabel)"
    }

    private var note: String? {
        profile.canWrite(.bassWave)
            ? nil
            : "This model has no measured write path for BassWave, so the reported level is shown "
              + "and cannot be changed here."
    }

    private func canStep(_ delta: Int) -> Bool {
        guard profile.canWrite(.bassWave), let bounds = session.bassWaveBounds,
              let level = session.bassWave else { return false }
        return bounds.contains(level + delta)
    }

    private func step(_ delta: Int) {
        guard let level = session.bassWave else { return }
        model.set(bassWave: level + delta)
    }

    private func stepButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(enabled ? Theme.accent : Theme.tertiaryText)
                .frame(width: 44, height: Theme.unselectedHeight)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.cardStroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .accessibilityLabel(symbol == "plus" ? "Increase BassWave" : "Decrease BassWave")
    }
}

// MARK: - Gestures

private struct GesturesCard: View {
    @ObservedObject var model: AppModel
    let session: Session
    let profile: DeviceProfile
    /// True while the app is drawing itself off-screen. See `Render`.
    @Environment(\.isRenderingSnapshot) private var isRenderingSnapshot

    var body: some View {
        Card(title: "Gestures", subtitle: subtitle, note: note) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(profile.gestures) { gesture in
                    HStack(spacing: 10) {
                        Label(gesture.label, systemImage: gesture.symbol)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.primaryText)
                            .frame(width: 140, alignment: .leading)
                        if isRenderingSnapshot {
                            // A `Menu` is AppKit-backed and `ImageRenderer` draws it as a coloured
                            // placeholder, so the drawing shows the label the menu would show.
                            pickerLabel(gesture)
                                .opacity(profile.canWrite(.gestures) ? 1 : 0.62)
                        } else {
                            Menu {
                                ForEach(gesture.actions) { action in
                                    Button {
                                        model.setGesture(gesture, action)
                                    } label: {
                                        Label("\(action.label)\(action == current(gesture) ? "  ✓" : "")",
                                              systemImage: action.symbol)
                                    }
                                }
                            } label: {
                                pickerLabel(gesture)
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .disabled(!profile.canWrite(.gestures))
                            .opacity(profile.canWrite(.gestures) ? 1 : 0.62)
                            .accessibilityLabel("\(gesture.label) action")
                            .accessibilityValue(current(gesture)?.label ?? "unknown")
                        }
                    }
                }
            }
        }
    }

    /// One picker's face, drawn identically inside the menu and in its place. The two must not
    /// drift, or the published picture would show something the window does not.
    private func pickerLabel(_ gesture: BudsProtocol.MediaGesture) -> some View {
        HStack {
            Text(current(gesture)?.label ?? "Unknown")
                .font(.system(size: 12))
            Spacer()
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
        }
        .foregroundStyle(Theme.primaryText)
        .padding(.horizontal, 10)
        .frame(height: Theme.unselectedHeight)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private func current(_ gesture: BudsProtocol.MediaGesture) -> BudsProtocol.GestureAction? {
        session.touchAction(gesture)
    }

    private var subtitle: String {
        session.touchRules.isEmpty
            ? "The gesture table has not been read yet."
            : "Read from the left earbud; a change is written to both, so the two cannot drift apart."
    }

    private var note: String? {
        var lines = ["Only action codes this hardware has been seen to store are offered — the "
                     + "firmware validates nothing, so a value outside the phone's own list would "
                     + "leave its screen with no selection."]
        if !profile.canWrite(.gestures) {
            lines.append("This model has no measured write path for gestures.")
        }
        lines.append("The in-call gesture is deliberately absent: its codes are unnamed in every "
                     + "description of this protocol, and guessing between answer and decline "
                     + "risks ending someone's call.")
        return lines.joined(separator: " ")
    }
}

// MARK: - Multi-connect

private struct LinkedDevicesCard: View {
    let session: Session
    let profile: DeviceProfile

    var body: some View {
        Card(title: "Multi-connect", subtitle: subtitle, note: note) {
            if session.linkedDevices.isEmpty {
                Text("No devices reported.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiaryText)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(session.linkedDevices.enumerated()), id: \.offset) { _, device in
                        HStack(spacing: 8) {
                            Image(systemName: device.deviceType?.symbol ?? "questionmark.circle")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.secondaryText)
                                .frame(width: 16)
                            Text(device.name)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.primaryText)
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            if device.isMainAudioDevice {
                                tag("audio", Theme.accent)
                            }
                            if device.isCurrentDevice {
                                tag("this Mac", Theme.good)
                            }
                            Text(stateLabel(device))
                                .font(.system(size: 10))
                                .foregroundStyle(device.state == .connected ? Theme.good : Theme.tertiaryText)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(device.name), \(stateLabel(device))"
                                            + (device.isCurrentDevice ? ", this Mac" : ""))
                    }
                }
            }
        }
    }

    private func stateLabel(_ device: BudsProtocol.LinkedDevice) -> String {
        device.state?.label ?? "unknown"
    }

    private func tag(_ text: String, _ colour: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(colour)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(colour.opacity(0.14), in: Capsule())
    }

    private var subtitle: String {
        "Read from the earbuds' own table: one getter, answered with the same body the device "
        + "pushes when the list changes."
    }

    private var note: String? {
        profile.canWrite(.multipoint)
            ? nil
            : "The vendor's SDK does implement a setter for this, and its shape is known — but it "
              + "has never been seen working on this hardware, so there is no way to make a linked "
              + "device come or go from here."
    }
}

// MARK: - Details

private struct DetailsCard: View {
    let session: Session

    var body: some View {
        Card(title: "Device", subtitle: "What the hardware reports, shown as it reports it.") {
            VStack(alignment: .leading, spacing: 7) {
                row("Firmware", session.firmware ?? "not reported")
                row("Codec", session.codec?.label ?? "not reported")
                row("Custom EQ", customEQ)
            }
        }
    }

    private var customEQ: String {
        switch session.hasCustomEQProfile {
        case true: return "a saved profile exists"
        case false: return "none saved"
        case nil: return "not reported"
        }
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(key)
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
                .frame(width: 74, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(Theme.primaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(key): \(value)")
    }
}

// MARK: - Activity

private struct ActivityCard: View {
    @ObservedObject var model: AppModel
    @State private var isExpanded = false

    var body: some View {
        Card(title: "Activity", subtitle: subtitle) {
            if isExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(model.activity.suffix(60).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Theme.secondaryText)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 140)
            }
            Button(isExpanded ? "Hide" : "Show \(model.activity.count) lines") {
                isExpanded.toggle()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(Theme.accent)
        }
    }

    private var subtitle: String {
        "What happened, in order. A declined write says so here — that is the only feedback a "
        + "setter gets, because the firmware answers before it acts."
    }
}

// MARK: - Footer

private struct ProvenanceFooter: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let profile = model.profile {
                Text("Profile \(profile.id) · \(profile.model) · \(profile.vendor)")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryText)
                let writable = Capability.allCases.filter { profile.canWrite($0) }
                Text(pdf(writable))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(model.registryDescription)
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    private func pdf(_ writable: [Capability]) -> String {
        let names = writable.map(\.title).sorted().joined(separator: ", ")
        return "Verified write paths: \(names.isEmpty ? "none" : names). "
             + "Firmware updates are out of scope permanently and their channel is never opened."
    }
}
