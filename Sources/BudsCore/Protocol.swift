import Foundation
import os

// MARK: - Noise control

/// A noise-control mode, as the firmware reports and accepts it: one 16-bit mask value.
///
/// The mode is *not* a small enum on the wire. Off, the four cancellation levels, both
/// passthrough modes and Adaptive all live in one bitfield, and the level is not a separate
/// field — it *is* the value.
///
/// An earlier version of this file read that field as a single byte and mapped `0x02` to
/// Transparency and `0x08` to "Max ANC". Measured against the hardware with `Tools/sniff.swift`,
/// those bytes command *Noise cancellation* and *Off* respectively, so two of the three
/// buttons sent a different mode than they claimed. The values below were each set and read
/// back one at a time.
enum NoiseMode: String, CaseIterable, Identifiable {
    case noiseCancellation
    case adaptive
    case transparency
    case off

    var id: String { rawValue }

    var label: String {
        switch self {
        case .noiseCancellation: return "Noise cancellation"
        case .adaptive: return "Adaptive"
        case .transparency: return "Transparency"
        case .off: return "Off"
        }
    }

    /// Audio metaphors, not people: a crossed-out waveform for cancellation, a magnifier over
    /// a waveform for Adaptive, an ear for hearing your surroundings, the universal off mark.
    ///
    /// Adaptive used to be `waveform.badge.ellipsis`, which does not exist — SwiftUI draws
    /// nothing at all for an unknown symbol, so the pill rendered with a blank where its
    /// icon should be, and nothing failed. Every name here is checked against the running OS
    /// by `Tools/check-symbols.swift`.
    var symbol: String {
        switch self {
        case .noiseCancellation: return "waveform.slash"
        case .adaptive: return "waveform.badge.magnifyingglass"
        case .transparency: return "ear"
        case .off: return "circle.slash"
        }
    }

    /// The mask the firmware stores for this mode. Noise cancellation is reported at
    /// whichever level it is on, so this is its High level — the same default the phone
    /// sends; `ANCLevel` carries the rest.
    var mask: UInt16 {
        switch self {
        case .noiseCancellation: return ANCLevel.high.mask
        case .adaptive: return 0x0800
        case .transparency: return 0x0100
        case .off: return 0x0008
        }
    }

    /// nil for a value this app does not model — a mask from a newer firmware, or the
    /// low byte of a lossy push with the high byte missing.
    init?(mask: UInt16) {
        switch mask {
        case 0x0008: self = .off
        case 0x0100: self = .transparency
        case 0x0800: self = .adaptive
        case 0x0010, 0x0020, 0x0040, 0x0080: self = .noiseCancellation
        default: return nil
        }
    }
}

/// How hard cancellation works while it is on.
///
/// The values are not in strength order and are not guessable: High is `0x0010`,
/// Moderate `0x0020`, Low `0x0040`, Auto `0x0080`. Each was set and read back in turn.
///
/// Declared strongest-first, matching the phone's own order — `allCases` is what the
/// picker renders, and it is deliberately not the wire order.
enum ANCLevel: String, CaseIterable, Identifiable {
    case high
    case moderate
    case low
    case auto

    var id: String { rawValue }

    var label: String {
        switch self {
        case .high: return "High"
        case .moderate: return "Moderate"
        case .low: return "Low"
        case .auto: return "Auto"
        }
    }

    var detail: String {
        switch self {
        case .high: return "Very noisy places — planes and trains"
        case .moderate: return "Noisy places — streets and malls"
        case .low: return "Quieter places — home and office"
        case .auto: return "The buds pick a level as your surroundings change"
        }
    }

    var mask: UInt16 {
        switch self {
        case .high: return 0x0010
        case .moderate: return 0x0020
        case .low: return 0x0040
        case .auto: return 0x0080
        }
    }

    init?(mask: UInt16) {
        switch mask {
        case 0x0010: self = .high
        case 0x0020: self = .moderate
        case 0x0040: self = .low
        case 0x0080: self = .auto
        default: return nil
        }
    }
}

/// Sound Master EQ presets.
///
/// `0x03` is skipped by the firmware entirely, and `0x04` is the custom slot — which cannot be
/// selected until a profile exists, so the UI offers it only when the session says one does.
/// `0x00` and `0x02` are measured; the names come from the vendor SDK's own preset table, and
/// which of the slots a given model actually fills is a capability-registry question, not one
/// this enum can answer.
enum EQPreset: String, CaseIterable, Identifiable {
    case balanced
    case clearVocals
    case bass
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .balanced: return "Balanced"
        case .clearVocals: return "Clear Vocals"
        case .bass: return "Bass"
        case .custom: return "Custom"
        }
    }

    var value: UInt8 {
        switch self {
        case .balanced: return 0x00
        case .clearVocals: return 0x01
        case .bass: return 0x02
        case .custom: return 0x04
        }
    }

    init?(value: UInt8) {
        switch value {
        case 0x00: self = .balanced
        case 0x01: self = .clearVocals
        case 0x02: self = .bass
        case 0x04: self = .custom
        default: return nil
        }
    }
}

/// Wire format for the `oppointeraction` RFCOMM channel on OnePlus / OPPO / realme earbuds.
///
/// Pure functions over bytes — no I/O — so `selfCheck()` can exercise them against captured
/// traffic without the hardware present.
///
///     aa <len:varint> 00 00 <cmd> <msgType> <seq> <payloadLen:u16le> <payload…>
///
/// `len` is a base-128 varint counting every byte after itself, so a frame is
/// `1 + len(varint) + len` bytes. There is no checksum: the two length fields are the only
/// integrity check, and agreeing on both is what tells a real frame from a stray sync byte.
enum BudsProtocol {

    static let sync: UInt8 = 0xaa

    /// Byte 5 of a frame. Byte 4 is the command and byte 5 the message type — *not* one
    /// little-endian 16-bit code, which mis-reads REGISTER (`00 85`) as "command 0x8500".
    /// The `0x0404`-style labels used in the reverse-engineering write-ups are just
    /// `(messageType << 8) | cmd`.
    enum MessageType: UInt8 {
        case request = 0x01
        case notification = 0x02
        case set = 0x04
        /// A settings push. The command byte names the subject using its *own* numbering,
        /// which does not match the getter ids — see `Command`.
        case stateChange = 0x05
        case reply = 0x81
        case setAck = 0x84
        case register = 0x85
    }

    /// Getter command ids, as used in requests and replies.
    ///
    /// Two of these are vocabulary rather than traffic: the app has never sent either, and they
    /// are here because they are part of the id space it enumerated. `0x0d` is
    /// `getFeatureSwitchStatus` in the vendor SDK's own labels, and its request is not a bare
    /// getter — it carries `[count]` and then the feature numbers to ask about, a list their
    /// per-model server config builds. This app has no screen that would need one, so the id
    /// stays named and unsent. `0x2f` is named by nothing on their side and has never been asked
    /// here either; it is kept so the id is not silently the app's own invention.
    enum Command: UInt8 {
        case firmware = 0x05
        case battery = 0x06
        case touch = 0x08
        case wear = 0x09
        case anc = 0x0c
        case miscConfig = 0x0d
        case eqPreset = 0x0f
        case connectedDevices = 0x12
        case customEQ = 0x22
        case bassWave = 0x24
        case capabilities = 0x2f
        /// `getCurrentCodecType` in the vendor SDK's own command labels.
        case codec = 0x14
    }

    /// The codec the link is using, from the `0x0114` getter.
    ///
    /// The ids and their names are the vendor SDK's: its "High audio" list is built from the
    /// same numbering and highlights the entry equal to the reported type (`CodecVO.kt`), so a
    /// name here is their label rather than an inference from the audio. On this hardware the
    /// getter answers `02`, which their list calls AAC — the app cannot see macOS's side of the
    /// negotiation, so what it shows is the buds' own word for the link.
    ///
    /// Read-only, deliberately: the setter for it (`setHighAudioCodecType`, `0x041a`) is one of
    /// the commands the vendor's SDK logs as unsupported, so nothing here sends it. An id the
    /// table does not name parses to nothing and the row reads as unknown, rather than being
    /// rounded to a codec the hardware never reported.
    enum Codec: UInt8 {
        case sbc = 0x01
        case aac = 0x02
        case ldac = 0x03
        case aptx = 0x04
        case aptxHD = 0x05
        case aptxAdaptive = 0x06
        case lhdc = 0x07
        case lhdcV5 = 0x08

        var label: String {
            switch self {
            case .sbc: return "SBC"
            case .aac: return "AAC"
            case .ldac: return "LDAC"
            // The vendor's own strings, underscores and all: they are what its list renders,
            // and `aptX` is a trademark whose case is theirs to set.
            case .aptx: return "APTX"
            case .aptxHD: return "APTX_HD"
            case .aptxAdaptive: return "APTX_ADAPTIVE"
            case .lhdc, .lhdcV5: return "LHDC"
            }
        }
    }

    /// Setter command ids. A **different namespace**, confirmed against the hardware: the EQ
    /// preset setter happens to match its getter (`0x06`), but BassWave's is `0x1B` against a
    /// getter of `0x24`, and touch's is `0x01` against `0x08`. Deriving one from the other
    /// looks plausible and simply does nothing — the firmware would not even acknowledge the
    /// wrong id in the one case tested.
    enum Setter: UInt8 {
        case find = 0x00
        case touch = 0x01
        case anc = 0x04
        case eqPreset = 0x06
        case bassWave = 0x1b
    }

    struct Frame {
        /// Byte 4: which subject.
        var cmd: UInt8
        /// Byte 5: request / reply / set / notification.
        var messageType: UInt8
        var sequence: UInt8
        var payload: [UInt8]
        var raw: [UInt8]

        /// `(messageType << 8) | cmd`, the label the protocol write-ups use.
        var opcode: UInt16 { UInt16(messageType) << 8 | UInt16(cmd) }

        /// Unsolicited status push. Family 1 of the three notification families: the command
        /// byte is `0x04` and the type is `0x02`, and `payload[0]` selects the topic.
        ///
        /// This used to require the command byte to be `0x0c`, from the ANC getter's id. The
        /// one family-1 frame this unit actually sends unprompted — the connected-device
        /// table — carries `0x04`, so the test rejected the only real example it had and every
        /// status push was silently ignored.
        var isStatusNotification: Bool {
            cmd == BudsProtocol.statusNotificationCommand
                && messageType == MessageType.notification.rawValue
        }
    }

    /// Byte 4 of a family-1 notification. Shared by set-ANC and family-2 pushes, which are
    /// told apart by the message type rather than by this byte.
    static let statusNotificationCommand: UInt8 = 0x04

    enum Update: Equatable {
        case noiseMode(NoiseMode)
        case ancLevel(ANCLevel)
        /// One slot at a time, and nil means "reported as unknown" — not "absent".
        ///
        /// A battery frame can carry a subset of the three slots, so a slot that is missing
        /// must keep its last value while a slot that is present but unreadable must be
        /// cleared. Bundling all three into one update collapsed those two cases together,
        /// and a case that had gone to sleep kept showing its last percentage forever.
        case battery(BatterySlot, Int?)
        /// Where one bud is. Only emitted for values `BudPlacement` recognises.
        case placement(BatterySlot, BudPlacement)
        case eqPreset(EQPreset)
        /// The BassWave level, −5…+5.
        case bassWave(Int)
        /// The buds' multi-connect table, whole. A table that cannot be read back is not an
        /// empty table: `linkedDevices(_:)` returns nil for one it cannot trust and the frame
        /// then yields no update at all, so a bad parse cannot silently clear the list.
        case linkedDevices([LinkedDevice])
        /// The codec the link negotiated. Read-only: the vendor's own setter for it
        /// (`setHighAudioCodecType`) is one of the commands its SDK logs as unsupported.
        case codec(Codec)
    }

    enum BatterySlot: UInt8 {
        case left = 0x01
        case right = 0x02
        case enclosure = 0x03
    }

    /// Where a bud is, decoded from the wear flags.
    ///
    /// These are bit flags, measured by moving the buds between an ear, a hand and the case:
    /// `0x01` = out of the case, `0x02` = in an ear, `0x04` = present at all. Only the three
    /// combinations actually observed are modelled; anything else falls out of
    /// `init?(rawValue:)` rather than being guessed into a state.
    ///
    /// This is what stops a bud charging in the case from being drawn as one in use, and it
    /// covers a gap in the battery report: a bud in the case drops out of that report
    /// entirely rather than reporting as unknown.
    enum BudPlacement: UInt8 {
        case notPresent = 0x00
        case inCase = 0x04
        /// Out of the case but not in an ear — being held, or worn on a cord.
        case outOfCase = 0x05
        case inEar = 0x07

        var isStowed: Bool { self == .inCase }
        var isWorn: Bool { self == .inEar }
    }

    /// One device in the buds' multi-connect table — the phone app's "Dual connection" list.
    ///
    /// This is the one phone-app screen with no counterpart on the Mac, and the reason is in
    /// the protocol: the table arrives as a push, and no setter for connecting or disconnecting
    /// a peer has ever been seen on the wire. So it is read-only here, and says only what the
    /// buds said.
    ///
    /// The field order and meanings are the vendor SDK's — `MultiConnectInformationElement` and
    /// the parser in its `CommandUtil` — not an inference from one sample. Under that layout the
    /// corpus frame consumes exactly to its last byte, which is what a wrong stride would not do.
    struct LinkedDevice: Equatable {
        /// The address the buds know the peer by. Phones and Macs use a private address that can
        /// change between sessions, so this is identity for drawing only: `isCurrentDevice` is
        /// what says which entry is this Mac.
        var address: String
        var name: String
        /// `nil` when the byte is a value the vendor numbering does not name.
        var state: ConnectionState?
        /// The entry the buds are talking to on this link — in practice, this Mac.
        var isCurrentDevice: Bool
        /// The entry currently carrying the audio.
        var isMainAudioDevice: Bool
        var isAudioActive: Bool
        /// What the peer is, from the vendor's own icon table, or `nil` where it has none.
        var deviceType: DeviceType?
    }

    /// The connection states the vendor's multi-device screen switches on. `0` is the state its
    /// list treats as available to connect, the others are named in its own messages ("handheld
    /// is in connecting state", "in disconnecting state"). Values outside these fall out of
    /// `init?(rawValue:)` rather than being guessed into a state.
    enum ConnectionState: Int, Equatable {
        case notConnected = 0
        case connecting = 1
        case connected = 2
        case disconnecting = 4
    }

    /// What a peer is, per the vendor's icon selection: `1` phone, `2` computer, `3` tablet,
    /// `4` watch, everything else its default icon. All three bits were zero in the one capture
    /// this app has, so the app draws the default too rather than assuming a laptop.
    enum DeviceType: Int, Equatable {
        case phone = 1
        case computer = 2
        case tablet = 3
        case watch = 4

        /// The vendor's icon table, said in this platform's vocabulary. The names live here
        /// rather than at the call site so `check-symbols.swift` can see them: SwiftUI draws
        /// nothing at all for a name the OS does not know.
        var symbol: String {
            switch self {
            case .phone: return "iphone"
            case .computer: return "laptopcomputer"
            case .tablet: return "ipad"
            case .watch: return "applewatch"
            }
        }
    }

    /// One row of the touch-gesture table.
    ///
    /// `type` is the context (`0x01` when not on a call, `0x06` during one) and `gesture` the
    /// physical action. The two are packed as a little-endian pair by the rest of the family
    /// — `0x0201` is "double tap in the media context", i.e. `type 01, gesture 02`.
    ///
    /// The vendor SDK reads the same four bytes as `deviceType`, `button`, `buttonAction` and
    /// `function` (`KeyFunctionInfo`) — the same order, so `side` is their `deviceType`, `type`
    /// their `button`, `gesture` their `buttonAction` and `action` their `function`. The names
    /// here are this app's reading of what the values mean on this hardware; the layout is the
    /// SDK's.
    struct TouchRule: Equatable {
        var side: UInt8
        var type: UInt8
        var gesture: UInt8
        var action: UInt8

        static let left: UInt8 = 0x01
        static let right: UInt8 = 0x02
        static let media: UInt8 = 0x01
    }

    /// The gestures the phone's "Earbud controls" screen offers.
    ///
    /// The codes are the `gesture` byte in the media context; `type` is always
    /// `TouchRule.media`. The in-call context (`type 0x06`) is deliberately absent — its two
    /// codes are unnamed in every published description of this protocol and both this unit
    /// and the reference unit store values for them that nothing documents. Guessing between
    /// "answer" and "decline" and writing the guess to the buds risks ending someone's call,
    /// which is not worth the feature.
    enum MediaGesture: UInt8, CaseIterable, Identifiable {
        case doubleTap = 0x02
        case tripleTap = 0x03
        case touchAndHold = 0x04
        case slide = 0x05

        var id: UInt8 { rawValue }

        var label: String {
            switch self {
            case .doubleTap: return "Double tap"
            case .tripleTap: return "Triple tap"
            case .touchAndHold: return "Touch and hold"
            case .slide: return "Slide"
            }
        }

        var symbol: String {
            switch self {
            case .doubleTap: return "hand.tap"
            case .tripleTap: return "hand.tap.fill"
            case .touchAndHold: return "hand.point.up.left"
            case .slide: return "hand.draw"
            }
        }

        /// What the phone offers for this gesture. The firmware validates nothing — it stores
        /// whatever it is sent, and a value outside the phone's own list leaves its UI with no
        /// selection at all — so the list is enforced here instead, exactly as with the EQ
        /// preset.
        ///
        /// Every code below was read off the reference hardware: they are the actions this app
        /// has actually seen stored, not a guess at the rest of the space.
        var actions: [GestureAction] {
            switch self {
            case .doubleTap, .tripleTap:
                return [.none, .playPause, .next, .previous, .voiceAssistant]
            case .touchAndHold:
                return [.none, .noiseControl, .voiceAssistant]
            case .slide:
                return [.none, .volumeControl]
            }
        }
    }

    /// What a gesture points at.
    enum GestureAction: UInt8, CaseIterable, Identifiable {
        case none = 0x00
        case playPause = 0x01
        case voiceAssistant = 0x03
        case previous = 0x05
        case next = 0x06
        case volumeControl = 0x07
        case noiseControl = 0x08

        var id: UInt8 { rawValue }

        var label: String {
            switch self {
            case .none: return "Do nothing"
            case .playPause: return "Play / pause"
            case .voiceAssistant: return "Voice assistant"
            case .previous: return "Previous track"
            case .next: return "Next track"
            case .volumeControl: return "Volume control"
            // "Noise control" collides with the section heading of the same name, and in a
            // menu of *actions* it reads as a destination rather than a verb. The gesture
            // cycles the mode; the label says so.
            case .noiseControl: return "Toggle noise control"
            }
        }

        var symbol: String {
            switch self {
            case .none: return "minus"
            case .playPause: return "playpause"
            case .voiceAssistant: return "mic"
            case .previous: return "backward.end.fill"
            case .next: return "forward.end.fill"
            case .volumeControl: return "speaker.wave.2"
            case .noiseControl: return "waveform.slash"
            }
        }
    }

    /// Entry id carrying the noise mode inside a `noiseMode` payload.
    private static let noiseModeID: UInt8 = 0x01

    // MARK: - Sending

    /// Packets to send once the channel opens. Status arrives unprompted, but OPOv1 expects
    /// a hello before it will accept commands.
    static func handshake() -> [[UInt8]] { [encodeHello()] }

    /// Builds a frame. `len` is a base-128 varint counting every byte after itself, so it
    /// covers the seven remaining header bytes plus the payload.
    ///
    /// The single-byte reading this replaced agrees with it for every frame under 128 bytes —
    /// which is all of them today — and mis-frames anything larger, silently: the length then
    /// predicts a short frame, the payload-length cross-check fails on the real one, and the
    /// whole thing is discarded as resynchronisation noise.
    static func makeFrame(_ b2: UInt8, _ b3: UInt8, cmd: UInt8, messageType: UInt8,
                          sequence: UInt8, payload: [UInt8]) -> [UInt8] {
        precondition(payload.count <= 0xffff, "payload length is a 16-bit field")
        var frame: [UInt8] = [sync]
        frame += encodeVarint(7 + payload.count)
        frame += [b2, b3, cmd, messageType, sequence,
                  UInt8(payload.count & 0xff), UInt8(payload.count >> 8)]
        frame += payload
        return frame
    }

    /// LEB128, little-endian — seven bits per byte, continuation bit high.
    static func encodeVarint(_ value: Int) -> [UInt8] {
        var remaining = value
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(remaining & 0x7f)
            remaining >>= 7
            if remaining > 0 { byte |= 0x80 }
            out.append(byte)
        } while remaining > 0
        return out
    }

    /// Decodes a varint.
    ///
    /// nil means the value is not a value: either the bytes ran out mid-value, or the pattern is
    /// longer than any legitimate varint (five bytes is the maximum here). Those two need
    /// opposite handling — one is a short read to wait on, the other is a bad byte to step over —
    /// so the caller tells them apart from the bytes rather than from this result.
    static func decodeVarint<C: Collection>(_ bytes: C) -> (value: Int, length: Int)?
    where C.Element == UInt8 {
        var value = 0, shift = 0, length = 0
        for byte in bytes {
            value |= Int(byte & 0x7f) << shift
            length += 1
            if byte & 0x80 == 0 { return (value, length) }
            shift += 7
            if shift > 28 { return nil }   // nothing legitimate is this long
        }
        return nil
    }

    /// A getter: message type `0x01`, with `cmd` naming the subject.
    static func encodeRequest(_ cmd: Command, payload: [UInt8] = []) -> [UInt8] {
        makeFrame(0x00, 0x00, cmd: cmd.rawValue, messageType: MessageType.request.rawValue,
                  sequence: nextSequence(), payload: payload)
    }

    /// Sets noise control from an explicit 16-bit mask.
    ///
    /// The field also accepts a few single-byte conveniences (`0x01` off, `0x02` NC at High,
    /// `0x04` transparency), which is why the older single-byte form appeared to work while
    /// mapping to the wrong modes. The explicit form is unambiguous and is the only one that
    /// can reach Adaptive or a specific level, so it is the only one sent.
    static func encodeSetNoiseMask(_ mask: UInt16) -> [UInt8] {
        makeFrame(0x00, 0x00, cmd: Setter.anc.rawValue,
                  messageType: MessageType.set.rawValue, sequence: nextSequence(),
                  payload: [0x01, 0x01, UInt8(mask & 0xff), UInt8(mask >> 8)])
    }

    static func encodeSetEQPreset(_ preset: EQPreset) -> [UInt8] {
        makeFrame(0x00, 0x00, cmd: Setter.eqPreset.rawValue,
                  messageType: MessageType.set.rawValue, sequence: nextSequence(),
                  payload: [preset.value])
    }

    /// BassWave: `[min][max][level]`, signed.
    ///
    /// The bounds are the *hardware's*, so they travel with the frame rather than being baked
    /// in. The getter reports them (see `bassWaveBounds(_:)`), so a session passes back what the
    /// device said and a model with a different range is written correctly without a code
    /// change. The default is the one range this project has measured, `−5…+5` on a OnePlus
    /// Buds 4 — a default for callers that have not read the getter, not a claim about every
    /// model. The self-check pins the default payload against the captured `basswave-reply-2`,
    /// so a firmware that moved the bounds fails a test rather than being written blind.
    static func encodeSetBassWave(_ level: Int, bounds: ClosedRange<Int> = -5...5) -> [UInt8] {
        let clamped = max(bounds.lowerBound, min(bounds.upperBound, level))
        return makeFrame(0x00, 0x00, cmd: Setter.bassWave.rawValue,
                         messageType: MessageType.set.rawValue, sequence: nextSequence(),
                         payload: [UInt8(bitPattern: Int8(clamping: bounds.lowerBound)),
                                   UInt8(bitPattern: Int8(clamping: bounds.upperBound)),
                                   UInt8(bitPattern: Int8(clamping: clamped))])
    }

    /// Rings the given buds — or, with an empty list, asks them to stop.
    ///
    /// The payload names the slots to ring, so naming none is the one stop request this
    /// vocabulary can express, and it needs no id the corpus does not already allow. A capture
    /// cannot settle whether the firmware honours an empty list — the setter is answered with a
    /// bare result byte whether it rings or not — so this stays a request, and the UI offers
    /// Stop beside Ring instead of claiming the tone is over.
    static func encodeFind(_ slots: [BatterySlot]) -> [UInt8] {
        // The count is one byte: more than 255 buds cannot be named. The UI offers two. Truncate
        // rather than trap, so a bad caller loses the command instead of the process.
        let ids = Array(slots.map(\.rawValue).prefix(255))
        return makeFrame(0x00, 0x00, cmd: Setter.find.rawValue,
                         messageType: MessageType.set.rawValue, sequence: nextSequence(),
                         payload: [UInt8(ids.count)] + ids)
    }

    /// One record of the getter's reply behind a count, per the "setter takes its getter's
    /// reply minus the status byte" rule that predicts every setter in this file.
    static func encodeSetTouch(_ rules: [TouchRule]) -> [UInt8] {
        // One count byte, so 255 records is the ceiling; the UI writes two, one per earbud.
        let rules = Array(rules.prefix(255))
        var payload: [UInt8] = [UInt8(rules.count)]
        for rule in rules { payload += [rule.side, rule.type, rule.gesture, rule.action] }
        return makeFrame(0x00, 0x00, cmd: Setter.touch.rawValue,
                         messageType: MessageType.set.rawValue, sequence: nextSequence(),
                         payload: payload)
    }

    /// Session opener. The buds answer it, and OPOv1 wants it before commands.
    static func encodeHello() -> [UInt8] {
        makeFrame(0x00, 0x00, cmd: 0x00, messageType: MessageType.request.rawValue,
                  sequence: nextSequence(), payload: [])
    }

    /// Monotonic per-session sequence byte.
    ///
    /// Static because nothing else in the framing carries state, and locked because a static
    /// mutable counter is the one piece of shared state in this file — the encoders are not
    /// declared main-actor, so two of them on different queues would otherwise race on `&+=`.
    private static let sequenceCounter = OSAllocatedUnfairLock(initialState: UInt8(0))

    static func nextSequence() -> UInt8 {
        sequenceCounter.withLock { counter in
            counter &+= 1
            return counter
        }
    }

    // MARK: - Receiving

    /// Pulls every complete frame out of `buffer`, leaving any partial tail behind.
    /// RFCOMM delivers arbitrary chunks, so frames both split and coalesce.
    static func drainFrames(from buffer: inout [UInt8]) -> [Frame] {
        var frames: [Frame] = []

        while true {
            // Resynchronise: drop anything before the next sync byte.
            guard let start = buffer.firstIndex(of: sync) else {
                buffer.removeAll()
                break
            }
            if start > 0 { buffer.removeFirst(start) }

            guard buffer.count >= 2 else { break }

            // A varint is at most five bytes and a continuation byte never terminates one, so
            // five of them in a row can never become a value however much more arrives. That is
            // a bad byte, not a short read, and `decodeVarint` returns nil for both. Waiting here
            // would be permanent: no frame could ever complete, so every frame after the bad one
            // would be dropped for the life of the channel while `rxBuffer` grew without bound.
            if buffer.count >= 6, buffer[1...5].allSatisfy({ $0 & 0x80 != 0 }) {
                buffer.removeFirst()
                continue
            }
            // Otherwise a truncated varint is not a bad frame, only a short read — wait for more.
            guard let (length, varintLength) = decodeVarint(buffer[1...]) else { break }

            // `length` counts the seven remaining header bytes plus the payload — the sync byte
            // and the varint are the other two — so anything smaller cannot be a frame, and the
            // payload-length field is 16-bit, so nothing larger can be one either. Both mean this
            // was not a frame boundary: step over the sync byte and look for the next one. The
            // upper bound matters as much as the lower: without it an overlong varint decodes to
            // a length no buffer will ever reach, which waits forever exactly like a poison byte.
            guard length >= 7, length <= 7 + 0xffff else {
                buffer.removeFirst()
                continue
            }

            let total = 1 + varintLength + length
            guard buffer.count >= total else { break }   // wait for the rest

            let raw = Array(buffer[0..<total])
            let body = 1 + varintLength
            let payloadLength = Int(raw[body + 5]) | Int(raw[body + 6]) << 8
            if body + 7 + payloadLength == total {
                frames.append(Frame(
                    cmd: raw[body + 2],
                    messageType: raw[body + 3],
                    sequence: raw[body + 4],
                    payload: Array(raw[(body + 7)...]),
                    raw: raw))
                buffer.removeFirst(total)
            } else {
                // The two length fields disagree: this was not a frame boundary.
                buffer.removeFirst()
            }
        }

        return frames
    }

    /// Decodes an unsolicited frame — a status notification or a settings push.
    static func interpret(_ frame: Frame) -> [Update] {
        if frame.isStatusNotification { return statusTopic(frame.payload) }
        if frame.messageType == MessageType.stateChange.rawValue {
            return settingsPush(frame)
        }
        return []
    }

    /// Decodes a reply the app asked for. Same bodies as the pushes, each behind a status
    /// byte, so one decoder serves both.
    static func decode(reply frame: Frame) -> [Update] {
        guard frame.messageType == MessageType.reply.rawValue else { return [] }
        switch frame.cmd {
        case Command.battery.rawValue:
            return battery(body(withoutStatus: frame))
        case Command.wear.rawValue:
            return wear(body(withoutStatus: frame))
        case Command.anc.rawValue:
            return anc(body(withoutStatus: frame))
        // The table, read back on request. The reply is the push's body behind a status byte,
        // which is why the same decoder serves it — and why the card can be current rather than
        // only as fresh as the last push.
        case Command.connectedDevices.rawValue:
            return linkedDevices(body(withoutStatus: frame)).map { [.linkedDevices($0)] } ?? []
        case Command.eqPreset.rawValue:
            guard let value = body(withoutStatus: frame).first,
                  let preset = EQPreset(value: value) else { return [] }
            return [.eqPreset(preset)]
        case Command.bassWave.rawValue:
            guard let level = bassWaveLevel(body(withoutStatus: frame)) else { return [] }
            return [.bassWave(level)]
        case Command.codec.rawValue:
            guard let id = body(withoutStatus: frame).first,
                  let codec = Codec(rawValue: id) else { return [] }
            return [.codec(codec)]
        default:
            return []
        }
    }

    /// The firmware string is ASCII, comma-separated, and does not fit the counted shape:
    /// `1,2,138,2,2,138,3,1,01,3,2,105` — component, ?, build, repeated.
    static func firmware(from frame: Frame) -> String? {
        guard frame.cmd == Command.firmware.rawValue,
              frame.messageType == MessageType.reply.rawValue,
              frame.payload.count >= 2,
              frame.payload[0] == statusOK else { return nil }
        return String(decoding: frame.payload.dropFirst(2), as: UTF8.self)
    }

    /// The touch-gesture table: `[status][count]` then `count` four-byte records.
    /// The request payload is ignored by the firmware, so this is always sent empty.
    static func touchRules(from frame: Frame) -> [TouchRule]? {
        guard frame.cmd == Command.touch.rawValue,
              frame.messageType == MessageType.reply.rawValue else { return nil }
        let body = body(withoutStatus: frame)
        guard let count = body.first else { return nil }
        var rules: [TouchRule] = []
        var index = 1
        for _ in 0..<Int(count) {
            guard index + 3 < body.count else { break }
            rules.append(TouchRule(side: body[index], type: body[index + 1],
                                   gesture: body[index + 2], action: body[index + 3]))
            index += 4
        }
        return rules
    }

    /// The BassWave level out of `[min][max][current]`, all signed.
    static func bassWaveLevel(_ body: [UInt8]) -> Int? {
        guard body.count >= 3 else { return nil }
        return Int(Int8(bitPattern: body[2]))
    }

    /// The bounds out of the same `[min][max][current]`, which the hardware states itself.
    ///
    /// This is why the setter takes its bounds as an argument: the device says what its range
    /// is, so nothing here needs to assume one. A range that does not read low-to-high is
    /// rejected rather than clamped, because a decoder that silently fixes a payload is inventing
    /// bytes.
    static func bassWaveBounds(_ body: [UInt8]) -> ClosedRange<Int>? {
        guard body.count >= 3 else { return nil }
        let low = Int(Int8(bitPattern: body[0]))
        let high = Int(Int8(bitPattern: body[1]))
        guard low <= high else { return nil }
        return low...high
    }

    /// The status byte a reply leads with, and the only value a decoder here will read past.
    ///
    /// `00` is a reply that carries an answer; `01` is the firmware declining the command.
    /// Both were measured: every getter this app sends answers `00`, and four of the getters the
    /// vendor's SDK names — hearing enhancement, its filter data, Zen mode, free-dialog recovery
    /// time (`0x0115`, `0x0116`, `0x0119`, `0x011d`) — answer a bare `01` instead of a body.
    /// Reading past the status would take `[01 03]` for three records, so a declined reply
    /// yields no update at all rather than a guess at what its leftovers meant.
    static let statusOK: UInt8 = 0x00

    private static func body(withoutStatus frame: Frame) -> [UInt8] {
        guard frame.payload.first == statusOK else { return [] }
        return Array(frame.payload.dropFirst())
    }

    /// Family 1: `cmd 0x04`, `type 0x02`. `payload[0]` selects the topic and the rest is the
    /// corresponding reply with its status byte removed.
    private static func statusTopic(_ payload: [UInt8]) -> [Update] {
        guard let topic = payload.first else { return [] }
        let body = Array(payload.dropFirst())
        guard !body.isEmpty else { return [] }
        switch topic {
        case 0x01: return battery(body)
        case 0x02: return wear(body)
        // The ANC push is lossy on this hardware: some captures carry the full 16-bit value,
        // others only its low byte, and the low byte of Transparency (0x0100) and Adaptive
        // (0x0800) is 0x00 either way. `anc` handles both and stays silent when the value is
        // ambiguous, so the poll is what actually keeps the panel honest.
        case 0x03: return anc(body)
        // The multi-connect table. The vendor's notification dispatcher numbers this event `6`
        // too, so this app's "topic" byte is its "event" byte.
        case 0x06: return linkedDevices(body).map { [.linkedDevices($0)] } ?? []
        default: return []
        }
    }

    /// The buds' multi-connect table: `[count]`, then `count` records of
    /// `[address 6][length][state][flags][nameLength][name]`.
    ///
    /// `length` is `3 + nameLength` — the record's bytes after itself — and both parsers stride
    /// by it: the corpus frame's two records start at 1 and 35 of a 55-byte body and the last
    /// one ends exactly at the end, which is the check that the layout is the vendor's and not
    /// a fit to one example.
    ///
    /// Returns nil — no update — rather than a partial list when anything does not add up: a
    /// record that runs past the body, a length byte that disagrees with the name it precedes,
    /// or a count that promises more records than the body holds. The vendor's parser discards
    /// the whole table in the same situations (it returns null), and the alternative is showing
    /// a device list that was half-read.
    static func linkedDevices(_ body: [UInt8]) -> [LinkedDevice]? {
        guard let count = body.first else { return nil }
        guard count > 0 else { return [] }
        var devices: [LinkedDevice] = []
        var index = 1
        for _ in 0..<Int(count) {
            // The five fields that are fixed width, then the name.
            guard index + 10 <= body.count else { return nil }
            let address = body[index..<(index + 6)]
                .map { String(format: "%02x", $0) }.joined(separator: ":")
            let length = Int(body[index + 6])
            let state = body[index + 7]
            let flags = body[index + 8]
            let nameLength = Int(body[index + 9])
            guard length == nameLength + 3, index + 10 + nameLength <= body.count else { return nil }
            let name = String(
                decoding: body[(index + 10)..<(index + 10 + nameLength)], as: UTF8.self)
            // The vendor skips an all-zero address: it is a placeholder slot, not a device.
            if address != "00:00:00:00:00:00" {
                devices.append(LinkedDevice(
                    address: address,
                    name: name,
                    state: ConnectionState(rawValue: Int(state)),
                    isCurrentDevice: flags & 0x01 != 0,
                    isMainAudioDevice: flags & 0x02 != 0,
                    isAudioActive: flags & 0x04 != 0,
                    deviceType: DeviceType(rawValue: Int(flags >> 3) & 0x07)))
            }
            index += 7 + length
        }
        return devices
    }

    /// Family 2: `type 0x05`, with the command byte naming the subject on its own numbering.
    ///
    /// The payload is the subject's *reply* payload minus its status byte — the same body a
    /// family-1 notification would carry, without a topic in front of it. So `0x0504`'s
    /// payload is the bare preset byte, not `[status][preset]`, and the two families share
    /// one set of decoders.
    private static func settingsPush(_ frame: Frame) -> [Update] {
        switch frame.cmd {
        case 0x04:   // EQ preset — a bare preset byte
            guard let value = frame.payload.first, let preset = EQPreset(value: value)
            else { return [] }
            return [.eqPreset(preset)]
        case 0x08:   // BassWave — `[min][max][current]`
            guard let level = bassWaveLevel(frame.payload) else { return [] }
            return [.bassWave(level)]
        default:
            return []
        }
    }

    private static func battery(_ body: [UInt8]) -> [Update] {
        guard let count = body.first else { return [] }
        return pairs(body, count: count).compactMap { id, raw in
            guard let slot = BatterySlot(rawValue: id) else { return nil }
            // A slot reads 0 while it is asleep or shut rather than dropping out of the
            // frame, and a genuinely flat battery is the rarer reading — so 0 means
            // unknown, and the UI shows a dash rather than a false 0%.
            let percent = Int(raw & 0x7f)
            return .battery(slot, percent == 0 ? nil : percent)
        }
    }

    private static func wear(_ body: [UInt8]) -> [Update] {
        guard let count = body.first else { return [] }
        return pairs(body, count: count).compactMap { id, flags in
            guard let slot = BatterySlot(rawValue: id),
                  let placement = BudPlacement(rawValue: flags) else { return nil }
            return .placement(slot, placement)
        }
    }

    private static func anc(_ body: [UInt8]) -> [Update] {
        guard let count = body.first, count == 1, body.count >= 3 else { return [] }
        guard body[1] == noiseModeID else { return [] }
        // Two bytes when the whole value is present, one when the push was lossy.
        let mask = body.count >= 4
            ? UInt16(body[2]) | UInt16(body[3]) << 8
            : UInt16(body[2])
        guard let mode = NoiseMode(mask: mask) else { return [] }
        guard mode == .noiseCancellation, let level = ANCLevel(mask: mask) else {
            return [.noiseMode(mode)]
        }
        return [.noiseMode(mode), .ancLevel(level)]
    }

    /// Reads `count` two-byte `[id][value]` records starting after the count.
    private static func pairs(_ body: [UInt8], count: UInt8) -> [(UInt8, UInt8)] {
        var out: [(UInt8, UInt8)] = []
        var index = 1
        for _ in 0..<Int(count) {
            guard index + 1 < body.count else { break }
            out.append((body[index], body[index + 1]))
            index += 2
        }
        return out
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    /// One-line summary of a frame, for the trace and for `Tools/sniff.swift`.
    static func describe(_ frame: Frame) -> String {
        let kind = MessageType(rawValue: frame.messageType).map { "\($0)" } ?? "unknown"
        return "cmd=\(String(format: "%02x", frame.cmd)) "
            + "type=\(String(format: "%02x", frame.messageType)) \(kind) "
            + "seq=\(String(format: "%02x", frame.sequence)) "
            + "payload=[\(hex(frame.payload))]"
    }

    // MARK: - Self check

    /// The outcome of a `selfCheck()` run.
    public struct SelfCheckResult {
        public var checks = 0
        public var failures: [String] = []
        public var passed: Bool { failures.isEmpty }
    }

    /// True when the process was started as `--selfcheck`. `BudsBar.launch()` reads this
    /// before it creates anything, so a check run never constructs an app.
    public static let isSelfCheckRun = CommandLine.arguments.contains("--selfcheck")

    /// Re-derives a frame's length fields from its payload and compares them with the bytes
    /// that are actually there.
    ///
    /// This is the invariant that makes a frame a frame: `len` is a varint covering
    /// `7 + payload.count`, and the payload-length field has to agree with it. Re-encoding is
    /// the honest way to test it — it is a property of the bytes rather than a second opinion
    /// about them — and it catches the class of mistake this file used to contain, where a
    /// typed-out fixture carried a `len` describing different bytes than it held.
    static func lengthFieldsAgree(_ frame: Frame) -> Bool {
        let declared = encodeVarint(7 + frame.payload.count)
        let body = 1 + declared.count
        // A frame is `sync + varint + 7 header bytes + payload`, so an empty-payload frame is
        // exactly `body + 7` bytes — this is a floor, not a strict bound. Getting it wrong made
        // this function disagree with `drainFrames`, which accepts that frame: the validator
        // called malformed the very shape the app sends as its own session opener.
        guard frame.raw.count >= body + 7 else { return false }
        guard Array(frame.raw[1..<body]) == declared else { return false }
        let payloadLength = Int(frame.raw[body + 5]) | Int(frame.raw[body + 6]) << 8
        return body + 7 + payloadLength == frame.raw.count
    }

    /// Runs every check against the captured corpus and reports, rather than trapping.
    ///
    /// `assert` would have been shorter, and was what this used, but it is compiled out of
    /// release builds — which is what ships. A protocol regression would then go out silently,
    /// as the app quietly commanding the wrong mode, which is exactly the bug these checks
    /// exist to prevent. Reporting a result instead means the same code runs as a real check
    /// from `build.sh`, from `swift test`, and as a launch-time guard in debug.
    @discardableResult
    public static func selfCheck() -> SelfCheckResult {
        selfCheck(corpus: CaptureCorpus.frames)
    }

    /// The same run against a corpus that is handed in rather than the one on disk, so that a
    /// test can degrade it. The contract is the one the crash broke: a corpus that does not add
    /// up comes back as *failures*, never as a trap. Every read below is total, and this is how
    /// that is checked rather than by reading the subscripts carefully and hoping.
    static func selfCheck(corpus: [CaptureCorpus.Capture]) -> SelfCheckResult {
        var result = SelfCheckResult()
        func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) {
            result.checks += 1
            if !condition() { result.failures.append(message()) }
        }

        // Every read below goes through these two, because `selfCheck` promises to *report* a
        // regression and a subscript that traps is the one way it cannot: the run dies with an
        // index-out-of-range and never prints the failures it had already collected. That is not
        // hypothetical. 1.0.0 crashed here — in the check that followed a failed count
        // assertion, reading element zero of what the assertion had just proved was not there.
        // A check may fail. It may not take the process down with it.
        func byte(_ bytes: [UInt8], _ index: Int) -> UInt8? {
            bytes.indices.contains(index) ? bytes[index] : nil
        }
        func tail(_ bytes: [UInt8], from index: Int) -> [UInt8]? {
            index >= 0 && index <= bytes.count ? Array(bytes[index...]) : nil
        }

        // MARK: The corpus itself

        // Every fixture has to *be* a frame before anything is decoded from it, and this is
        // the check whose absence caused the crash: the fixtures were typed out by hand, one
        // carried a `len` varint that disagreed with its own payload-length field,
        // `drainFrames` correctly rejected it, and the check that followed indexed `[0]` of
        // an empty array. A bad fixture now fails here, by name, and the decoders below run
        // against a placeholder — so the report names the cause instead of the process dying.
        var captured: [String: Frame] = [:]
        let placeholder = Frame(cmd: 0, messageType: 0, sequence: 0, payload: [], raw: [])
        for capture in corpus {
            var buffer = capture.bytes
            let parsed = drainFrames(from: &buffer)
            check(parsed.count == 1 && buffer.isEmpty,
                  "\(capture.name): capture is not exactly one frame "
                  + "(\(parsed.count) parsed, \(buffer.count) bytes left over)")
            guard let frame = parsed.first else {
                captured[capture.name] = placeholder
                continue
            }
            check(lengthFieldsAgree(frame),
                  "\(capture.name): length fields disagree with the bytes they describe")
            captured[capture.name] = frame
        }

        func capture(_ name: String) -> Frame {
            guard let frame = captured[name] else {
                check(false, "\(name): no such capture in the corpus")
                return placeholder
            }
            return frame
        }

        /// A variant of a captured frame with a different payload.
        ///
        /// States the hardware did not happen to be in while the capture was taken — a case
        /// that has gone to sleep, a charging bit, a push cut short — are derived here rather
        /// than typed out. `makeFrame` recomputes both length fields, so a derived fixture
        /// cannot disagree with itself. That is the whole lesson of the crash: bytes are fine,
        /// hand-written lengths are not.
        func derived(_ name: String, from base: Frame, payload: [UInt8],
                     cmd: UInt8? = nil, messageType: UInt8? = nil) -> Frame {
            var buffer = makeFrame(0x00, 0x00, cmd: cmd ?? base.cmd,
                                   messageType: messageType ?? base.messageType,
                                   sequence: base.sequence, payload: payload)
            let parsed = drainFrames(from: &buffer)
            guard parsed.count == 1, buffer.isEmpty, let frame = parsed.first else {
                check(false, "\(name): derived frame is not well formed")
                return placeholder
            }
            return frame
        }

        /// A family-1 notification derived from a capture. The command byte and message type
        /// are what make it a notification at all, so they are set rather than inherited — the
        /// first version of this derived them from a *reply* and every check downstream failed
        /// for a reason that had nothing to do with the decoder under test.
        func notification(_ name: String, from base: Frame, payload: [UInt8]) -> Frame {
            derived(name, from: base, payload: payload,
                    cmd: statusNotificationCommand, messageType: MessageType.notification.rawValue)
        }

        // MARK: Framing

        // A 299-byte payload produces a 306-byte length, which needs two varint bytes. A
        // single-byte reading predicts 180 and mis-frames the stream from there on.
        check(encodeVarint(306) == [0xb2, 0x02], "306 is a two-byte varint")
        check(encodeVarint(7) == [0x07], "small lengths stay one byte")
        check(decodeVarint([0xb2, 0x02])?.value == 306, "varint round-trips")
        check(decodeVarint([0x80]) == nil, "a dangling continuation byte is not a value")

        let big = makeFrame(0, 0, cmd: 0x1f, messageType: 0x81, sequence: 1,
                            payload: Array(repeating: 0, count: 299))
        check(byte(big, 1) == 0xb2 && byte(big, 2) == 0x02, "big frame length is a varint")
        var bigBuffer = big
        let bigFrames = drainFrames(from: &bigBuffer)
        check(bigFrames.count == 1 && bigFrames[0].payload.count == 299,
               "a 299-byte payload parses whole")

        // An empty payload is legal, and it is not a corner case: it is the shape of the app's
        // own session opener. The validator used to require `raw.count > body + 7`, which is
        // exactly the size of that frame, so it called the app's own hello malformed while the
        // parser accepted it — one invariant written twice, and disagreeing.
        var emptyBuffer = encodeHello()
        let emptyFrames = drainFrames(from: &emptyBuffer)
        check(emptyFrames.count == 1, "an empty-payload frame parses")
        check(emptyFrames.first.map { lengthFieldsAgree($0) } == true,
              "an empty-payload frame satisfies the length invariant")

        // A byte pattern that can never be a varint has to be stepped over, not waited on. Waiting
        // is right for a short read; a poison byte needs the opposite, and confusing the two makes
        // the parser deaf for the life of the channel. Each input is one bad frame followed by a
        // good one, so this checks not just that nothing hangs but that the parse recovers.
        let poisons: [(String, [UInt8])] = [
            ("five continuation bytes", [sync, 0x80, 0x80, 0x80, 0x80, 0x80]),
            ("an overlong varint length", [sync, 0x80, 0x80, 0x80, 0x80, 0x7f]),
        ]
        for (label, poison) in poisons {
            var buffer = poison + big
            let recovered = drainFrames(from: &buffer)
            check(recovered.count == 1 && recovered[0].payload.count == 299 && buffer.isEmpty,
                  "\(label): the parser resynchronises instead of stalling")
        }

        // MARK: The status byte

        // Every reply this app sends leads with a status byte, and both of its values have now
        // been seen. `00` is an answer. `01` is the firmware declining the command — measured
        // while asking the getters the vendor's SDK names: `0x0115` and `0x0116` (hearing
        // enhancement), `0x0119` (Zen mode) and `0x011d` (free-dialog recovery) answer a bare
        // `01` where `0x0106` answers a battery. So a decoder may only read past a `00`, and
        // this is the suite-wide version of that: nothing in the corpus is a declined reply.
        for (name, frame) in captured where frame.messageType == MessageType.reply.rawValue {
            check(frame.payload.first == statusOK,
                  "\(name): a captured reply does not lead with the OK status byte")
        }
        let declined = derived("anc-reply-declined", from: capture("anc-reply-off"),
                               payload: [0x01, 0x03])
        check(decode(reply: declined).isEmpty,
              "a declined reply yields no update rather than three records")
        let declinedFirmware = derived("firmware-reply-declined", from: capture("firmware-reply"),
                                       payload: [0x01, 0x04, 0x31])
        check(firmware(from: declinedFirmware) == nil,
              "a declined firmware read is not a version string")

        // MARK: Handshake

        let hello = capture("hello-reply")
        check(hello.cmd == 0x00 && hello.messageType == MessageType.reply.rawValue,
              "the hello reply is a single reply frame")
        check(Array(hello.payload.dropFirst())
                == [0xff, 0x77, 0x5a, 0xea, 0x67, 0x0e, 0x20, 0x07],
              "the hello reply is the static 8-byte value, not a session token")
        check(interpret(hello).isEmpty, "the hello reply is not a status update")

        // MARK: Battery

        let battery = capture("battery-reply")
        check(decode(reply: battery) == [.battery(.left, 20), .battery(.right, 20)],
              "battery reply, case absent: \(decode(reply: battery))")

        // The same report arriving as a family-1 notification, topic 0x01. Derived, because
        // the notification body is the reply body with a topic in front of it — that identity
        // is the reason one decoder serves both.
        let batteryPush = notification("battery-push", from: battery,
                                       payload: [0x01] + Array(battery.payload.dropFirst()))
        check(interpret(batteryPush) == [.battery(.left, 20), .battery(.right, 20)],
              "battery push: \(interpret(batteryPush))")

        // A sleeping case reads as unknown, not 0%.
        let sleepingCase = notification("battery-push-sleeping-case", from: battery,
                                        payload: [0x01, 0x03, 0x01, 0x14, 0x02, 0x14, 0x03, 0x00])
        check(interpret(sleepingCase) == [.battery(.left, 20), .battery(.right, 20),
                                          .battery(.enclosure, nil)],
              "a sleeping case is unknown, and says so rather than staying silent")

        // A slot that is absent from the report must not be invented: the two-bud capture has
        // no case entry at all, and the decoder emits nothing for it.
        check(interpret(batteryPush).contains(.battery(.enclosure, 20)) == false,
              "an absent slot is not the same as an unknown one")

        // The charging bit lives in the top bit and must not be read as part of the level.
        let charging = derived("battery-reply-charging", from: battery,
                               payload: [0x00, 0x02, 0x01, 0x94, 0x02, 0x14])
        check(decode(reply: charging) == [.battery(.left, 20), .battery(.right, 20)],
              "0x80 is a charging flag, not 148%: \(decode(reply: charging))")

        // MARK: Wear

        let wear = capture("wear-reply")
        check(decode(reply: wear) == [.placement(.left, .inEar),
                                      .placement(.right, .inEar),
                                      .placement(.enclosure, .inCase)],
              "wear flags: \(decode(reply: wear))")

        // Being held is neither in the ear nor put away, and must not be rounded to either.
        let held = derived("wear-held", from: wear,
                           payload: [0x00, 0x03, 0x01, 0x05, 0x02, 0x07, 0x03, 0x04])
        check(decode(reply: held) == [.placement(.left, .outOfCase),
                                      .placement(.right, .inEar),
                                      .placement(.enclosure, .inCase)],
              "held is its own state: \(decode(reply: held))")

        // MARK: Noise control

        // These four are the table the app got wrong: it sent 0x02 for Transparency and 0x08
        // for ANC, and the firmware stored Noise cancellation and Off.
        check(decode(reply: capture("anc-reply-off")) == [.noiseMode(.off)], "0x0008 is Off")
        check(decode(reply: capture("anc-reply-nc-high"))
                == [.noiseMode(.noiseCancellation), .ancLevel(.high)],
              "0x0010 is Noise cancellation at High, not Transparency")
        check(decode(reply: capture("anc-reply-transparency")) == [.noiseMode(.transparency)],
              "0x0100 is Transparency")
        check(decode(reply: capture("anc-reply-adaptive")) == [.noiseMode(.adaptive)],
              "0x0800 is Adaptive")

        for (name, level) in [("anc-reply-nc-moderate", ANCLevel.moderate),
                              ("anc-reply-nc-low", ANCLevel.low),
                              ("anc-reply-nc-auto", ANCLevel.auto)] {
            check(decode(reply: capture(name))
                    == [.noiseMode(.noiseCancellation), .ancLevel(level)],
                  "\(name) is Noise cancellation at \(level.label)")
        }

        // A mask from newer firmware is ignored rather than rounded to a nearby mode.
        let unknownMask = derived("anc-reply-unknown-mask", from: capture("anc-reply-off"),
                                  payload: [0x00, 0x01, 0x01, 0x00, 0x40])
        check(decode(reply: unknownMask).isEmpty, "an unmodelled mask yields no update")

        // The push carries only the low byte, so 0x00 cannot be told apart between
        // Transparency and Adaptive and must produce nothing at all.
        let lossyOff = notification("anc-push-low-byte-off", from: capture("anc-reply-off"),
                                    payload: [0x03, 0x01, 0x01, 0x08])
        check(interpret(lossyOff) == [.noiseMode(.off)], "the low byte still identifies Off")
        let lossyAmbiguous = notification("anc-push-low-byte-ambiguous", from: capture("anc-reply-off"),
                                          payload: [0x03, 0x01, 0x01, 0x00])
        check(interpret(lossyAmbiguous).isEmpty,
              "a truncated push is not evidence of Transparency")

        // Every mode and level the UI can select reads back as the firmware would describe it.
        // The base is a real readback, so the header and both length fields stay well formed —
        // but the value is generated, so this proves only that the mask table and its inverse
        // agree. The captured `anc-reply-*` checks above are what pin the masks themselves.
        for mode in NoiseMode.allCases {
            let reply = derived("anc-reply-\(mode.rawValue)", from: capture("anc-reply-off"),
                                payload: [0x00, 0x01, 0x01,
                                          UInt8(mode.mask & 0xff), UInt8(mode.mask >> 8)])
            check(decode(reply: reply).contains(.noiseMode(mode)),
                  "\(mode.label) round-trips: \(decode(reply: reply))")
        }
        for level in ANCLevel.allCases {
            let reply = derived("anc-reply-\(level.rawValue)", from: capture("anc-reply-off"),
                                payload: [0x00, 0x01, 0x01,
                                          UInt8(level.mask & 0xff), UInt8(level.mask >> 8)])
            check(decode(reply: reply).contains(.ancLevel(level)),
                  "level \(level.label) round-trips: \(decode(reply: reply))")
        }

        // MARK: EQ, BassWave, firmware

        let eqBalanced = capture("eq-reply-balanced")
        let eqBass = capture("eq-reply-bass")
        check(decode(reply: eqBalanced) == [.eqPreset(.balanced)],
              "the Balanced readback: \(decode(reply: eqBalanced))")
        check(decode(reply: eqBass) == [.eqPreset(.bass)],
              "the Bass readback: \(decode(reply: eqBass))")

        // The buds push EQ changes as family 2: type 0x05, the subject in the command byte on
        // its own numbering, and the payload equal to the getter's reply payload minus its
        // status byte. Asserting that identity is what lets one set of decoders serve both.
        let eqPush = capture("eq-push-bass")
        check(interpret(eqPush) == [.eqPreset(.bass)], "the EQ push uses its own numbering")
        let eqPushBalanced = capture("eq-push-balanced")
        check(interpret(eqPushBalanced) == [.eqPreset(.balanced)], "the Balanced EQ push")
        check(eqPush.payload == Array(eqBass.payload.dropFirst()),
              "the push body is the reply body minus the status byte: \(hex(eqPush.payload))")

        let bass0 = capture("basswave-reply-0")
        let bass2 = capture("basswave-reply-2")
        check(decode(reply: bass0) == [.bassWave(0)], "a signed BassWave level")
        check(decode(reply: bass2) == [.bassWave(2)], "and another")

        // The codec, read with an empty payload from `0x0114`. Its id space is the vendor's
        // own list (`CodecVO.kt` numbers the "High audio" entries the same way), so the check
        // that every id it names is in this table is what keeps the labels theirs: an id the
        // table does not name is no update rather than a guess.
        check(decode(reply: capture("codec-reply")) == [.codec(.aac)],
              "the codec readback is AAC: \(decode(reply: capture("codec-reply")))")
        check((1...8).allSatisfy { Codec(rawValue: UInt8($0)) != nil },
              "every codec id the vendor's list carries has a name here")
        check(Codec(rawValue: 0x09) == nil, "an id the vendor's list does not carry is unnamed")
        let unnamedCodec = derived("codec-reply-unnamed", from: capture("codec-reply"),
                                   payload: [0x00, 0x09])
        check(decode(reply: unnamedCodec).isEmpty,
              "an unnamed codec id yields no update rather than a near match")
        let declinedCodec = derived("codec-reply-declined", from: capture("codec-reply"),
                                    payload: [0x01, 0x02])
        check(decode(reply: declinedCodec).isEmpty, "a declined codec read is not a codec")

        // Not observed on this unit — the phone's own writes are what raise it — so it is
        // derived from the family-2 shape with subject 0x08, whose payload is the 0x041B
        // setter's body byte for byte.
        let bassPush = derived("basswave-push", from: eqPush,
                               payload: [0xfb, 0x05, 0x02], cmd: 0x08)
        check(interpret(bassPush) == [.bassWave(2)], "the BassWave push: \(interpret(bassPush))")

        check(firmware(from: capture("firmware-reply")) == "1,2,138,2,2,138,3,1,01,3,2,105",
              "firmware is an ASCII string, not a binary structure")

        let customEQ = capture("custom-eq-reply")
        check(customEQ.payload.dropFirst().first == 0x00,
              "this unit has no saved custom EQ profile: \(hex(customEQ.payload))")

        // MARK: Touch

        let touch = capture("touch-reply")
        let rules = touchRules(from: touch)
        check(rules?.count == 18, "18 gesture records, got \(rules?.count ?? -1)")
        check(rules?.first == TouchRule(side: 0x01, type: 0x01, gesture: 0x01, action: 0x00),
              "first record")
        check(rules?.last == TouchRule(side: 0x02, type: 0x06, gesture: 0x06, action: 0x1c),
              "the record walk closes exactly on the end of the payload")

        // MARK: The setter namespace

        // A set is acknowledged by a `0x84` frame addressed to the *setter* id, so the
        // captured acks are evidence from the hardware for the ids this file sends — and for
        // the claim that the setter ids are a different namespace from the getters'.
        let setOff = encodeSetNoiseMask(NoiseMode.off.mask)
        check(setOff.count == 13, "an ANC set is 13 bytes: \(hex(setOff))")
        check(tail(setOff, from: 9) == [0x01, 0x01, 0x08, 0x00],
              "the explicit 16-bit mask, not the single byte that cannot express Adaptive")
        check(byte(setOff, 4) == Setter.anc.rawValue && byte(setOff, 4) == capture("setack-anc").cmd,
              "the ANC setter id is the one the hardware acknowledges")
        check(byte(setOff, 5) == MessageType.set.rawValue, "and it is a set, not a request")
        var setBuffer = setOff
        let setFrames = drainFrames(from: &setBuffer)
        check(setFrames.count == 1 && setBuffer.isEmpty, "the set frame parses as one frame")
        check(interpret(setFrames.first ?? placeholder).isEmpty,
              "a set frame is not a status update")

        let setEQ = encodeSetEQPreset(.bass)
        check(tail(setEQ, from: 9) == Array(eqBass.payload.dropFirst()),
              "the EQ setter takes its getter's reply payload minus the status byte")
        check(byte(setEQ, 4) == capture("setack-eq").cmd, "the EQ setter id is the acknowledged one")

        let setBass = encodeSetBassWave(2)
        check(tail(setBass, from: 9) == Array(bass2.payload.dropFirst()),
              "the BassWave setter echoes the getter's bounds: \(hex(setBass))")
        check(byte(setBass, 4) == Setter.bassWave.rawValue
                && byte(setBass, 4) == capture("setack-basswave").cmd,
              "BassWave's setter is 0x1B, not the getter's 0x24")
        check(encodeSetBassWave(99).last == 0x05, "the level is clamped to the hardware range")
        check(encodeSetBassWave(-99).last == 0xfb, "clamped at the bottom too")

        // A touch write is one record behind its count, and the record it writes back has to
        // be the one that was read. That is the guarantee the gesture editor depends on:
        // every write is a verbatim re-send of a record the buds already store.
        if let rule = rules?.first(where: { $0.type == TouchRule.media
                                            && $0.side == TouchRule.left }) {
            let setTouch = encodeSetTouch([rule])
            check(tail(setTouch, from: 9) == [0x01, rule.side, rule.type, rule.gesture, rule.action],
                  "one touch record behind its count: \(hex(setTouch))")
            check(byte(setTouch, 4) == Setter.touch.rawValue, "the touch setter id")
        } else {
            check(false, "the capture has no media-context record on the left to write back")
        }

        // Find is a count-prefixed id list. These three payloads are the ones measured
        // independently against the hardware, so the encoder is checked against bytes it did
        // not produce.
        check(tail(encodeFind([.left]), from: 9) == [0x01, 0x01], "find left only")
        check(tail(encodeFind([.right]), from: 9) == [0x01, 0x02], "find right only")
        check(tail(encodeFind([.left, .right]), from: 9) == [0x02, 0x01, 0x02], "find both")
        // Stop is the same setter naming no buds at all, so its whole payload is the zero count.
        check(tail(encodeFind([]), from: 9) == [0x00], "find stop names no buds")

        // MARK: Frames that must not move anything

        // The device table is the one family-1 notification this unit sends unprompted, and
        // topic `0x06` is the multi-connect table. Its layout is the vendor SDK's own parser,
        // and this capture is what holds that parser to account: read under it, the second
        // record begins at byte 35 of the 55-byte body and ends exactly at the end, which a
        // wrong stride would not do.
        func decodedTable(of frame: Frame) -> [LinkedDevice]? {
            for update in interpret(frame) + decode(reply: frame) {
                if case .linkedDevices(let devices) = update { return devices }
            }
            return nil
        }

        let devices = capture("notify-devices")
        check(devices.isStatusNotification, "a 0x0204 frame is a status notification")
        let table = decodedTable(of: devices) ?? []
        check(table.count == 2, "the device table names two devices")
        check(table.first?.name == "Shashank’s MacBook Pro", "the first device's name")
        check(table.first?.address == "26:68:69:83:be:b0", "and its address, byte for byte")
        check(table.first?.state == .connected, "the Mac reads connected")
        check(table.first?.isCurrentDevice == true, "and is the device the buds talk to")
        check(table.first?.isMainAudioDevice == false && table.first?.isAudioActive == false,
              "with no audio flag set")
        check(table.first?.deviceType == nil, "its device-type bits are unset in this capture")
        check(table.dropFirst().first?.name == "shsxnk S23", "the second device's name")
        check(table.dropFirst().first?.state == .notConnected, "the phone reads not connected")
        check(table.dropFirst().first?.isCurrentDevice == false, "and is not this Mac")

        // And the same table read back on request. The reply is the push's body behind a status
        // byte, so one decoder serves both — and the two captures are what prove it: they line
        // up byte for byte apart from that status byte and the phone's state, which had moved
        // from not connected to connected in between. Any other difference would mean one of
        // them had not been read right.
        let reply = capture("multiconnect-reply")
        let readBack = decodedTable(of: reply) ?? []
        check(readBack.count == 2, "the getter's reply names the same two devices")
        check(readBack.map(\.name) == table.map(\.name), "with the same names")
        check(readBack.dropFirst().first?.state == .connected,
              "and the phone connected, which is the byte the push predates")
        check(decode(reply: reply) == [.linkedDevices(readBack)], "a reply decodes as an update")
        check(interpret(reply).isEmpty, "a reply is not a notification")

        let replyBody = Array(reply.payload.dropFirst())
        let tableBody = Array(devices.payload.dropFirst())
        if replyBody.count == tableBody.count, tableBody.count > 42 {
            check(tableBody[42] == 0x00, "the push's phone state byte is 0")
            check(replyBody[42] == 0x02, "the reply's is 2")
            var aligned = tableBody
            aligned[42] = 0x02
            check(aligned == replyBody, "and every other byte of the two bodies is identical")
        } else {
            check(false, "the two device-table captures carry bodies of equal length")
        }

        // A table that does not add up is no table: a record running past the body, a length
        // byte that disagrees with the name it precedes, and a count promising more records
        // than the body holds all yield nil — so a half-read list cannot reach the UI as a fact.
        check(linkedDevices(Array(tableBody.dropLast(4))) == nil, "a truncated record is no table")
        var mismatched = tableBody
        mismatched[7] = 0x1c
        check(linkedDevices(mismatched) == nil, "a length byte that disagrees is no table")
        check(linkedDevices([0x02]) == nil, "a count with no records is no table")
        check(linkedDevices([0x03] + tableBody) == nil, "a count past the body is no table")
        check(linkedDevices([]) == nil, "a body with no count is no table")
        check(linkedDevices([0x00]) == [], "a zero count is an empty table, not a failure")
        // An all-zero address is a placeholder slot: the vendor's parser skips it rather than
        // listing a device that has no address.
        var zeroed = tableBody
        for index in 1...6 { zeroed[index] = 0x00 }
        check(linkedDevices(zeroed)?.count == 1, "a placeholder address is skipped")

        for name in ["setack-anc", "setack-eq", "setack-basswave"] {
            check(interpret(capture(name)).isEmpty, "\(name) is never a status update")
        }

        // MARK: Resilience

        // Two frames coalesced in one read.
        var coalesced = battery.raw + eqBass.raw
        check(drainFrames(from: &coalesced).count == 2, "coalesced frames")
        check(coalesced.isEmpty, "and nothing is left over")

        // One frame split across two reads: the tail must be held, not misparsed.
        var split = Array(battery.raw.prefix(6))
        check(drainFrames(from: &split).isEmpty, "a partial frame is withheld")
        split.append(contentsOf: battery.raw.dropFirst(6))
        check(drainFrames(from: &split).count == 1, "the frame completes across reads")

        // Leading garbage before the sync byte must be skipped, not fatal.
        var garbage: [UInt8] = [0xff, 0xff] + battery.raw
        check(drainFrames(from: &garbage).count == 1, "resynchronised past garbage")

        // A varint cut in half by the chunk boundary must wait, not resync.
        var cutVarint: [UInt8] = [0xaa, 0xb2]
        check(drainFrames(from: &cutVarint).isEmpty, "a half-read varint waits")
        check(cutVarint.count == 2, "and keeps its bytes")

        // A frame whose length fields disagree is not a frame: it is dropped and the scan
        // resumes, rather than being handed to a decoder as though it were one. This is the
        // behaviour the crash depended on being right.
        var malformed = battery.raw
        // Claim one byte more than is present. Guarded, because a corpus short enough to make this
        // write illegal has already failed the framing checks above — and this must not be the
        // thing that ends the run.
        if malformed.indices.contains(1) { malformed[1] = 0x0e }
        check(drainFrames(from: &malformed).isEmpty, "a lying length field is rejected")

        return result
    }

    /// Prints the check results and exits non-zero if any failed. Called by `build.sh` and by
    /// the test suite, so a protocol regression fails the build instead of shipping.
    public static func runSelfCheckAndExit() -> Never {
        let result = selfCheck()
        for failure in result.failures {
            FileHandle.standardError.write(Data("selfCheck FAILED: \(failure)\n".utf8))
        }
        let summary = result.passed
            ? "selfCheck passed: \(result.checks) checks\n"
            : "selfCheck FAILED: \(result.failures.count) of \(result.checks) checks\n"
        FileHandle.standardError.write(Data(summary.utf8))
        exit(result.passed ? 0 : 1)
    }
}
