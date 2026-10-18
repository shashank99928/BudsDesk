import Foundation

/// The state machine. The only object that talks to a transport, and the only one that owns
/// device state.
///
/// Three things about this class are deliberate and load-bearing:
///
/// 1. **It owns no timer.** The host drives `poll()`. A timer inside the session would make the
///    session untestable without waiting, and the master rule for this project is that a
///    headless run must pump the run loop rather than sleep. A host that wants a 2-second poll
///    installs a 2-second timer; a test calls `poll()` and asserts what came out.
///
/// 2. **No write ever commits UI state.** `set(mode:)` sends a frame and asks for a read-back.
///    The displayed value changes only when a *reply* changes it. A declined write therefore
///    looks like a control snapping back, which is the correct behaviour and the only honest
///    one: the firmware acknowledges writes long before it acts on them, and sometimes not at
///    all.
///
/// 3. **Every write is gated by the registry, not by this code.** If the device's profile does
///    not say `writable` + `measured` for a capability, there is no frame this class will send
///    for it, whatever the UI asks for.
public final class Session {

    public enum Phase: Equatable, Sendable {
        /// Nothing open. The device may be paired, absent, or asleep.
        case closed
        /// The host asked for a connection and the transport has not answered yet. This is the
        /// state a person sees for the first second or two after the buds wake up, and the one
        /// the UI has to render as "reading…" rather than as empty boxes.
        case opening
        /// The control channel is open and answering.
        case ready
    }

    // MARK: Identity and wiring

    public let profile: DeviceProfile
    public let transport: Transport
    /// The name the OS reports for the device, which may differ from the profile's model name.
    public var advertisedName: String?
    /// Called whenever any observable state changes. The UI redraws; a CLI prints.
    public var onChange: (() -> Void)?
    /// A human-readable line about what the session is doing. Tracing, not protocol.
    public var log: (String) -> Void

    // MARK: State

    public private(set) var phase: Phase = .closed
    public private(set) var battery = BatteryLevels()
    public private(set) var placement = Placement()
    public private(set) var mode: NoiseMode?
    public private(set) var ancLevel: ANCLevel?
    public private(set) var eqPreset: EQPreset?
    public private(set) var hasCustomEQProfile: Bool?
    public private(set) var bassWave: Int?
    /// The range the *device* reports. nil until it has said, and the write path refuses until
    /// then rather than falling back to another model's range.
    public private(set) var bassWaveBounds: ClosedRange<Int>?
    public private(set) var firmware: String?
    public private(set) var codec: BudsProtocol.Codec?
    public private(set) var touchRules: [BudsProtocol.TouchRule] = []
    public private(set) var linkedDevices: [BudsProtocol.LinkedDevice] = []
    public private(set) var lastError: String?
    public private(set) var lastFrameAt: Date?
    /// Capabilities that have been written and not yet confirmed by a read-back. The UI shows
    /// these as pending rather than as applied — which is the whole point of reading back.
    public private(set) var unconfirmedWrites: Set<Capability> = []

    // MARK: Derived

    public var isReady: Bool { phase == .ready }

    /// Whether anything has actually been read yet, so the UI can tell "not read" from "absent".
    public var hasReadAnything: Bool {
        firmware != nil || battery.left != nil || battery.right != nil
            || mode != nil || eqPreset != nil
    }

    /// Whether a case is there. The wear report is the only evidence while the case is asleep,
    /// and a sleeping case is its usual state.
    public var isCaseReported: Bool { placement.isCaseReported || battery.enclosure != nil }

    /// What a gesture currently does, taken from the left earbud: the phone keeps the two sides
    /// in step, so the left is the row the UI shows and the one it writes back to both.
    public func touchAction(_ gesture: BudsProtocol.MediaGesture) -> BudsProtocol.GestureAction? {
        touchRules.first {
            $0.side == BudsProtocol.TouchRule.left
                && $0.type == BudsProtocol.TouchRule.media
                && $0.gesture == gesture.rawValue
        }.flatMap { BudsProtocol.GestureAction(rawValue: $0.action) }
    }

    // MARK: Private

    private var rxBuffer: [UInt8] = []
    private var readbackTicks = 0
    private var started = false

    public init(transport: Transport, profile: DeviceProfile,
                advertisedName: String? = nil,
                log: @escaping (String) -> Void = { _ in }) {
        self.transport = transport
        self.profile = profile
        self.advertisedName = advertisedName
        self.log = log
        transport.onOpen = { [weak self] in self?.transportDidOpen() }
        transport.onData = { [weak self] in self?.transportDidReceive($0) }
        transport.onClose = { [weak self] in self?.transportDidClose($0) }
    }

    // MARK: - Lifecycle

    public func start() {
        guard !started else { return }
        started = true
        phase = .opening
        lastError = nil
        log("session: opening \(transport.description) as \(profile.provenanceLine)")
        notify()
        transport.open()
    }

    public func stop() {
        started = false
        transport.close()
    }

    /// The transport opened. Sends the session HELLO and asks for everything.
    ///
    /// The reads are sent immediately rather than after a delay: a real transport is free to
    /// defer them, and the original's 0.4-second wait existed to let the handshake land on
    /// IOBluetooth, which is a property of that transport and lives there now.
    public func transportDidOpen() {
        guard phase != .ready else { return }
        phase = .ready
        lastError = nil
        for packet in BudsProtocol.handshake() { transport.write(packet) }
        log("session: control channel open")
        notify()
        readAll()
    }

    /// The transport closed, or failed to open. Clears everything it was showing, because a
    /// stale reading behind a dead link is the specific lie this app exists not to tell.
    public func transportDidClose(_ reason: String?) {
        guard phase != .closed else { return }
        phase = .closed
        // Cleared so the host can start again: a device that went away and came back is the
        // normal case, not an error.
        started = false
        rxBuffer.removeAll()
        readbackTicks = 0
        clearState()
        if let reason { lastError = reason }
        log("session: channel closed — \(reason ?? "no reason given")")
        notify()
    }

    /// Bytes arrived. Fragments are normal: framing is this layer's business, not the radio's.
    public func transportDidReceive(_ bytes: [UInt8]) {
        guard phase == .ready else { return }
        lastFrameAt = Date()
        rxBuffer.append(contentsOf: bytes)
        let frames = BudsProtocol.drainFrames(from: &rxBuffer)
        guard !frames.isEmpty else { return }
        for frame in frames { apply(frame) }
        notify()
    }

    // MARK: - Reading

    /// Everything, once. A device does not push its settings, so a fresh channel knows nothing
    /// until it is asked.
    public func readAll() {
        guard phase == .ready else { return }
        for packet in stateRequests() { transport.write(packet) }
        for packet in settingsRequests() { transport.write(packet) }
    }

    /// The poll the host drives, and the only periodic traffic there is.
    ///
    /// ANC is the important one: the push that carries it is lossy on the measured hardware (the
    /// low byte alone, which cannot tell Transparency from Adaptive) and *no* push arrived at all
    /// for our own writes. Without the poll the surface would keep showing whatever was last
    /// commanded, or whatever the phone changed minutes ago.
    public func poll() {
        guard phase == .ready else { return }
        for packet in stateRequests() { transport.write(packet) }
        // While a write is unconfirmed, the settings are re-asked too, and stop being asked once
        // the read-back arrives or the attempts run out. A control that stays pending forever
        // would be as dishonest as one that claims success.
        guard readbackTicks > 0 else { return }
        for packet in settingsRequests() { transport.write(packet) }
        readbackTicks -= 1
        if readbackTicks == 0, !unconfirmedWrites.isEmpty {
            log("readback: giving up on \(unconfirmedWrites.map(\.rawValue).sorted())")
            unconfirmedWrites.removeAll()
            notify()
        }
    }

    private func stateRequests() -> [[UInt8]] {
        [
            // A getter that needs its argument: the firmware answers nothing at all when the
            // ANC read carries no payload.
            BudsProtocol.encodeRequest(.anc, payload: [0x01, 0x01]),
            BudsProtocol.encodeRequest(.battery),
            BudsProtocol.encodeRequest(.wear),
            // The linked-device table is pushed too, but not reliably at the moment it changes:
            // in this project's own corpus a push and a getter reply a second apart disagree
            // about whether the phone was connected. The getter is one empty frame and its reply
            // is the push's body behind a status byte, so the poll is what keeps the list honest.
            BudsProtocol.encodeRequest(.connectedDevices),
            // The codec belongs to the link, not to a settings screen: it can change when the
            // audio renegotiates, so it is polled rather than read once.
            BudsProtocol.encodeRequest(.codec),
        ]
    }

    private func settingsRequests() -> [[UInt8]] {
        [
            BudsProtocol.encodeRequest(.eqPreset),
            BudsProtocol.encodeRequest(.bassWave),
            BudsProtocol.encodeRequest(.customEQ),
            BudsProtocol.encodeRequest(.firmware),
            BudsProtocol.encodeRequest(.touch),
        ]
    }

    // MARK: - Writing
    //
    // Every write below is the same shape: check the registry, check the value, send the frame,
    // then ask for a read-back. Nothing is assigned to a displayed value here. The four checks
    // that make this safe are `writes()`, `offers(_:_:)`, `write(_:_:)` and `beginReadback()`.

    /// Whether the registry allows a write path at all. Refusing here is what makes an
    /// unconfirmed capability genuinely unwritable rather than merely discouraged.
    public func canWrite(_ capability: Capability) -> Bool { profile.canWrite(capability) }

    @discardableResult
    public func set(mode requested: NoiseMode) -> Bool {
        guard writable(.noiseControl), offers(.noiseControl, requested.rawValue) else { return false }
        // The mask carries both the mode and, for cancellation, the level — they are the same
        // field. Reusing the level the buds last reported is what makes this a no-op for someone
        // who has already chosen one on the phone.
        let level = requested == .noiseCancellation ? (ancLevel ?? .high) : nil
        guard write(BudsProtocol.encodeSetNoiseMask(level?.mask ?? requested.mask), .noiseControl)
        else { return false }
        beginReadback()
        return true
    }

    @discardableResult
    public func set(ancLevel requested: ANCLevel) -> Bool {
        guard writable(.noiseControl), offers(.noiseControl, requested.rawValue) else { return false }
        guard write(BudsProtocol.encodeSetNoiseMask(requested.mask), .noiseControl) else { return false }
        beginReadback()
        return true
    }

    @discardableResult
    public func set(eqPreset requested: EQPreset) -> Bool {
        guard writable(.equalizer), offers(.equalizer, requested.rawValue) else { return false }
        // The custom slot is a real preset value and cannot be selected until a profile exists —
        // the firmware would store it and leave the phone's own picker with no selection.
        if requested == .custom, hasCustomEQProfile != true {
            lastError = "There is no saved custom profile to select."
            return false
        }
        guard write(BudsProtocol.encodeSetEQPreset(requested), .equalizer) else { return false }
        beginReadback()
        return true
    }

    @discardableResult
    public func set(bassWave level: Int) -> Bool {
        guard writable(.bassWave) else { return false }
        // The bounds are the device's. Until it has stated them, there is no range to clamp to
        // and no honest frame to send, so the write waits rather than assuming another model's.
        guard let bounds = bassWaveBounds else {
            lastError = "The earbuds have not reported their BassWave range yet."
            return false
        }
        guard write(BudsProtocol.encodeSetBassWave(level, bounds: bounds), .bassWave) else {
            return false
        }
        beginReadback()
        return true
    }

    /// Re-points one gesture on **both** earbuds.
    ///
    /// Only the two changed records are sent, so a byte mis-read anywhere else in the table cannot
    /// be written back, and the two sides cannot drift apart — which is exactly the state the
    /// phone's own screen cannot represent.
    @discardableResult
    public func setGesture(_ gesture: BudsProtocol.MediaGesture,
                           action: BudsProtocol.GestureAction) -> Bool {
        guard writable(.gestures), offers(.gestures, gesture.registryName) else { return false }
        // The firmware validates nothing: it stores whatever it is sent, and a value outside the
        // phone's own list leaves its UI with no selection at all. The restriction lives here.
        guard gesture.actions.contains(action) else {
            lastError = "\(gesture.label) cannot be set to \(action.label)."
            return false
        }
        let rules = [BudsProtocol.TouchRule.left, BudsProtocol.TouchRule.right].map {
            BudsProtocol.TouchRule(side: $0, type: BudsProtocol.TouchRule.media,
                                   gesture: gesture.rawValue, action: action.rawValue)
        }
        guard write(BudsProtocol.encodeSetTouch(rules), .gestures) else { return false }
        beginReadback()
        return true
    }

    /// Rings a bud so its owner can find it.
    ///
    /// Offered only when the registry has a measured write path for it. On the measured model it
    /// does not: the setter exists and its ack has been seen, but nothing distinguishes accept
    /// from reject and no recording of a ring was kept. See `DECISIONS.md` D5.
    @discardableResult
    public func find(_ slots: [BudsProtocol.BatterySlot] = [.left, .right]) -> Bool {
        guard writable(.findMyEarbuds) else { return false }
        return write(BudsProtocol.encodeFind(slots), .findMyEarbuds)
    }

    /// Asks the buds to end a tone that `find` started.
    ///
    /// The vendor app only ever rings. This re-uses the find setter with an empty slot list — the
    /// same request as "ring nothing" — and the UI words it as a request rather than a fact,
    /// because whether the firmware honours it can only be settled by ear.
    @discardableResult
    public func stopFind() -> Bool {
        guard writable(.findMyEarbuds) else { return false }
        return write(BudsProtocol.encodeFind([]), .findMyEarbuds)
    }

    // MARK: - Write plumbing

    private func writable(_ capability: Capability) -> Bool {
        guard profile.canWrite(capability) else {
            lastError = profile.spec(capability) == nil
                ? "\(profile.model) does not have \(capability.title)."
                : "\(profile.model) has no verified \(capability.title) write path."
            notify()
            return false
        }
        return true
    }

    private func offers(_ capability: Capability, _ value: String) -> Bool {
        guard profile.values(capability).contains(value) else {
            lastError = "\(profile.model) does not offer that \(capability.title) setting."
            notify()
            return false
        }
        return true
    }

    private func write(_ packet: [UInt8], _ capability: Capability) -> Bool {
        guard phase == .ready else {
            lastError = "Not connected."
            notify()
            return false
        }
        guard transport.write(packet) else {
            lastError = "The radio refused that command."
            notify()
            return false
        }
        unconfirmedWrites.insert(capability)
        notify()
        return true
    }

    /// A write is acknowledged long before it is reflected, so the read-back is asked for now
    /// *and* folded into the next couple of polls. This is the delay the single-device app
    /// implemented with two timers; here it is two ticks of a timer the host already runs.
    private func beginReadback() {
        readbackTicks = 2
        for packet in settingsRequests() { transport.write(packet) }
    }

    // MARK: - Applying frames

    private func apply(_ frame: BudsProtocol.Frame) {
        // Three replies do not fit the counted-update shape and are decoded on their own.
        if let version = BudsProtocol.firmware(from: frame) {
            if firmware != version {
                firmware = version
                unconfirmedWrites.remove(.firmware)
            }
            return
        }
        if let rules = BudsProtocol.touchRules(from: frame) {
            if touchRules != rules {
                touchRules = rules
                unconfirmedWrites.remove(.gestures)
            }
            return
        }
        // The custom-EQ reply is a whole profile table when one exists and a bare `00 00` when
        // none does. Only the first byte past the status is needed to know which: the profile
        // editor itself is out of scope, but the preset picker has to know whether the custom
        // slot is selectable at all.
        if frame.cmd == BudsProtocol.Command.customEQ.rawValue,
           frame.messageType == BudsProtocol.MessageType.reply.rawValue {
            hasCustomEQProfile = frame.payload.count >= 2 && frame.payload[1] > 0
            return
        }
        // The BassWave range is stated inside the getter's own body, so it is read from the same
        // reply the level is: `[status][min][max][current]`.
        if frame.cmd == BudsProtocol.Command.bassWave.rawValue,
           frame.messageType == BudsProtocol.MessageType.reply.rawValue {
            noteBassWaveBounds(Array(frame.payload.dropFirst()))
        }
        for update in BudsProtocol.interpret(frame) { apply(update) }
        // The same bodies come back as replies to our own requests, one status byte longer.
        for update in BudsProtocol.decode(reply: frame) { apply(update) }
    }

    private func apply(_ update: BudsProtocol.Update) {
        switch update {
        case .linkedDevices(let devices):
            guard linkedDevices != devices else { break }
            log("linked devices: \(devices.map(\.name).joined(separator: ", "))")
            linkedDevices = devices
            unconfirmedWrites.remove(.multipoint)
        case .eqPreset(let value):
            eqPreset = value
            unconfirmedWrites.remove(.equalizer)
        case .bassWave(let value):
            bassWave = value
            unconfirmedWrites.remove(.bassWave)
        case .codec(let value):
            guard codec != value else { break }
            log("codec: \(value.label)")
            codec = value
        case .noiseMode(let value):
            if mode != value { log("mode reported: \(value.label)") }
            mode = value
            // A level only means something while cancellation is on. A reply carries mode and level
            // together, so when the mode arrives without one — Transparency, Adaptive, or a lossy
            // push of a cancellation mask — the previous level is no longer true and has to go.
            // Without this, leaving cancellation on Auto and switching to Adaptive reads back as
            // "Adaptive (Auto)": a level the buds are not using, still on screen.
            if value != .noiseCancellation { ancLevel = nil }
            unconfirmedWrites.remove(.noiseControl)
        case .ancLevel(let value):
            if ancLevel != value { log("level reported: \(value.label)") }
            ancLevel = value
            unconfirmedWrites.remove(.noiseControl)
        case .battery(let slot, let level):
            // Assigned, not merged: nil here means the buds reported the slot as unknown, and a
            // slot they did not mention produces no update at all.
            battery[slot] = level

        case .placement(let slot, let where_):
            guard placement[slot] != where_ else { break }
            placement[slot] = where_
            // Only on the move out of use, not on every report of it. A bud put away drops out of
            // the battery report entirely, and an absent slot keeps its last reading — so the
            // reading it had while in use would stand on the surface indefinitely. Clearing it
            // once is enough: an awake case goes on reporting the bud inside it, and the next
            // report fills the value back in within seconds.
            if !where_.isUsable {
                switch slot {
                case .left: battery.left = nil
                case .right: battery.right = nil
                case .enclosure: break
                }
            }
        }
    }

    /// The BassWave range, which arrives inside a `.bassWave` update's own body and is therefore
    /// read from the same reply rather than from a separate getter. Kept here rather than in
    /// `apply(_:)` because the range is device state too, and the write path needs it.
    private func noteBassWaveBounds(_ body: [UInt8]) {
        guard let bounds = BudsProtocol.bassWaveBounds(body) else { return }
        if bassWaveBounds != bounds { bassWaveBounds = bounds }
    }

    /// Everything a live channel had, gone. Nothing is preserved across a disconnect except the
    /// intent to reconnect, which lives in the host — a stale reading behind a dead link is the
    /// specific lie this app exists not to tell.
    private func clearState() {
        battery = BatteryLevels()
        placement = Placement()
        mode = nil
        ancLevel = nil
        eqPreset = nil
        bassWave = nil
        bassWaveBounds = nil
        touchRules = []
        linkedDevices = []
        hasCustomEQProfile = nil
        firmware = nil
        codec = nil
        unconfirmedWrites.removeAll()
        lastFrameAt = nil
    }

    private func notify() { onChange?() }
}
