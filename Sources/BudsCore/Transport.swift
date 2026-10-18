import Foundation

/// The seam between the protocol and the radio.
///
/// Everything above this line is bytes in and bytes out. The session never learns what a
/// transport is; a transport never learns what a frame is. That is what lets the same framing,
/// the same decoders and the same session drive IOBluetooth on macOS, a WinRT RFCOMM stream on
/// Windows and a BlueZ socket on Linux without a decoder changing.
///
/// **Threading.** The session holds no locks and assumes nothing: the host must deliver every
/// callback on one thread (the main thread, for the macOS app). Transports are free to do their
/// work on a background queue, as IOBluetooth requires, as long as they hop back before calling.
public protocol Transport: AnyObject {
    /// The channel opened and the control session can start. Set by the session before `open()`.
    var onOpen: (() -> Void)? { get set }
    /// Bytes arrived. May be a fragment of a frame, or several frames at once — the session
    /// owns the accumulation buffer, because framing is the protocol's business, not the radio's.
    var onData: (([UInt8]) -> Void)? { get set }
    /// The channel closed, or failed to open. The reason is for a human.
    var onClose: ((String?) -> Void)? { get set }

    /// What is being talked to, for the log line. e.g. `RFCOMM 15 (oppointeraction)`.
    var description: String { get }

    var isOpen: Bool { get }

    /// Begin opening. Asynchronous: success arrives as `onOpen`, failure as `onClose(reason)`.
    func open()

    /// Close, and call back no further. Safe to call when already closed.
    func close()

    /// Hand bytes to the radio. False means they were not sent at all — not that they were
    /// declined, which is a protocol-level answer that arrives as a reply.
    @discardableResult
    func write(_ bytes: [UInt8]) -> Bool
}

/// A transport that answers from a recording instead of a radio.
///
/// This is not a test double for convenience: it is how `--replay`, the golden snapshots and the
/// session tests all drive the *real* session through the *real* decoders with no radio and no
/// flakiness. A test that pages the hardware fights the running app for the channel and then
/// fails for reasons that have nothing to do with the code.
public final class ScriptedTransport: Transport {
    public var onOpen: (() -> Void)?
    public var onData: (([UInt8]) -> Void)?
    public var onClose: ((String?) -> Void)?

    /// The frames this transport will deliver, in order.
    public let frames: [CaptureCorpus.Capture]
    /// Everything the session has written, in order. What the session *sends* is half the
    /// protocol, and a recording only ever holds the other half.
    public private(set) var written: [[UInt8]] = []
    public var opensOnStart = true
    public private(set) var isOpen = false
    public var description: String { "scripted (\(frames.count) frames)" }

    public init(frames: [CaptureCorpus.Capture], opensOnStart: Bool = true) {
        self.frames = frames
        self.opensOnStart = opensOnStart
    }

    public func open() {
        guard opensOnStart else { return }
        isOpen = true
        onOpen?()
    }

    public func close() {
        guard isOpen else { return }
        isOpen = false
        onClose?("scripted transport closed")
    }

    @discardableResult
    public func write(_ bytes: [UInt8]) -> Bool {
        guard isOpen else { return false }
        written.append(bytes)
        return true
    }

    /// Deliver every frame, one at a time, exactly as the radio would.
    public func deliverAll() {
        for frame in frames { deliver(frame.bytes) }
    }

    /// Deliver one frame's bytes.
    public func deliver(_ bytes: [UInt8]) {
        guard isOpen else { return }
        onData?(bytes)
    }

    /// Fail the open, so the not-connected path can be exercised without a radio.
    public func failToOpen(reason: String) {
        isOpen = false
        onClose?(reason)
    }

    /// The frames the session wrote, decoded for a human: `["01/0x0c", …]`.
    public var writtenSummary: [String] {
        written.compactMap { bytes in
            var buffer = bytes
            guard let frame = BudsProtocol.drainFrames(from: &buffer).first else { return nil }
            return String(format: "%02x/%02x", frame.cmd, frame.messageType)
        }
    }
}
