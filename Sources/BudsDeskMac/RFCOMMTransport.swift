import Foundation
import IOBluetooth
import BudsCore

/// The macOS `Transport`: one vendor RFCOMM channel, over IOBluetooth.
///
/// Everything protocol-shaped lives above this type. What is here is the part that is genuinely
/// macOS's own: paging the device, resolving the control service's channel from SDP, opening the
/// channel asynchronously and moving bytes.
///
/// Three things about this code were learned the hard way and are load-bearing:
///
/// - **The SDP query has to be run in-process before the channel is opened.** The records cached
///   at pairing time are not always enough, and an open without a fresh query does not fail — it
///   simply never completes.
/// - **The channel is exclusive.** Only one process may hold it. A stale holder makes the next
///   open fail *silently*, so a "discovery returned nothing" symptom is usually exclusivity or
///   TCC, not a protocol problem.
/// - **macOS grants Bluetooth access per binary (TCC).** A process without it sees an empty
///   paired-device list, not an error.
public final class RFCOMMTransport: NSObject, Transport, IOBluetoothRFCOMMChannelDelegate {

    public var onOpen: (() -> Void)?
    public var onData: (([UInt8]) -> Void)?
    public var onClose: ((String?) -> Void)?

    /// The device's Bluetooth address. The baseband link is opened to this, not to a name.
    public let address: String
    // `override` because NSObject already has one: without it the protocol requirement and
    // the inherited property collide, and the compiler says so.
    override public var description: String {
        "RFCOMM (\(DeviceCatalog.controlServiceUUIDString)) → \(address)"
    }

    public private(set) var isOpen = false

    private var device: IOBluetoothDevice?
    private var channel: IOBluetoothRFCOMMChannel?
    private var cancelled = false
    private var closed = false
    /// Serialises everything that touches IOBluetooth's blocking calls: `openConnection` blocks
    /// until the baseband link is up or times out, and `performSDPQuery` blocks too.
    private let queue = DispatchQueue(label: "dev.budsdesk.rfcomm", qos: .userInitiated)

    /// How long to wait for the SDP record after asking for a fresh query. Forty quarter-seconds
    /// is the budget the single-device app settled on, and it is generous: a query that has not
    /// answered in ten seconds is not going to.
    private static let sdpAttempts = 40
    private static let sdpInterval: TimeInterval = 0.25

    public init(address: String) {
        self.address = address
        super.init()
    }

    // MARK: - Transport

    public func open() {
        cancelled = false
        closed = false
        queue.async { [weak self] in self?.openOnBackground() }
    }

    public func close() {
        cancelled = true
        guard let channel else {
            if isOpen { finish("Closed.") }
            return
        }
        self.channel = nil
        channel.close()
        finish("Closed by the app.")
    }

    @discardableResult
    public func write(_ bytes: [UInt8]) -> Bool {
        guard let channel, isOpen else { return false }
        guard bytes.count <= Int(UInt16.max) else { return false }
        var copy = bytes
        let result = copy.withUnsafeMutableBytes { raw in
            channel.writeAsync(raw.baseAddress, length: UInt16(raw.count), refcon: nil)
        }
        // Traced only once the write was accepted, so the log records what went on the wire and
        // not what was attempted.
        if result == kIOReturnSuccess { Trace.record(.sent, bytes) }
        return result == kIOReturnSuccess
    }

    // MARK: - Opening

    private func openOnBackground() {
        guard let device = IOBluetoothDevice(addressString: address) else {
            fail("That device is not paired any more.")
            return
        }
        self.device = device

        // The baseband link first. A sleeping case answers with a page timeout, which is the
        // normal state of the hardware rather than an error worth alarming anyone about.
        let link = device.openConnection()
        guard link == kIOReturnSuccess else {
            fail(Self.describe(link))
            return
        }
        guard !cancelled else { return }

        // Then a fresh SDP query, in-process. Without it the open never completes, silently.
        device.performSDPQuery(nil)
        let uuid = IOBluetoothSDPUUID(bytes: DeviceCatalog.controlServiceUUIDBytes, length: 16)
        var record: IOBluetoothSDPServiceRecord?
        for _ in 0..<Self.sdpAttempts {
            if cancelled { return }
            record = device.getServiceRecord(for: uuid)
            if record != nil { break }
            Thread.sleep(forTimeInterval: Self.sdpInterval)
        }
        guard let record else {
            fail("The device is connected but does not advertise the control service.")
            return
        }

        var channelID: BluetoothRFCOMMChannelID = 0
        guard record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else {
            fail("The control service has no RFCOMM channel.")
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, !self.cancelled else { return }
            var opened: IOBluetoothRFCOMMChannel?
            let result = device.openRFCOMMChannelAsync(&opened, withChannelID: channelID,
                                                       delegate: self)
            if result == kIOReturnSuccess {
                self.channel = opened
            } else {
                self.fail(Self.describe(result))
            }
        }
    }

    // MARK: - Delegate

    public func rfcommChannelOpenComplete(_ channel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        guard error == kIOReturnSuccess else {
            self.channel = nil
            fail(Self.describe(error))
            return
        }
        guard !cancelled else {
            channel?.close()
            self.channel = nil
            return
        }
        isOpen = true
        self.channel = channel
        onOpen?()
    }

    public func rfcommChannelData(_ channel: IOBluetoothRFCOMMChannel!,
                                  data dataPointer: UnsafeMutableRawPointer!,
                                  length dataLength: Int) {
        guard let dataPointer, dataLength > 0 else { return }
        let bytes = Array(UnsafeBufferPointer(
            start: dataPointer.assumingMemoryBound(to: UInt8.self), count: dataLength))
        // Traced here rather than in the session: this is the byte stream as the radio delivered
        // it, before any reassembly. A capture wants what the hardware said, fragments and all.
        Trace.record(.received, bytes)
        onData?(bytes)
    }

    public func rfcommChannelClosed(_ channel: IOBluetoothRFCOMMChannel!) {
        self.channel = nil
        finish("The control channel closed.")
    }

    // MARK: - Reporting

    /// Report a failure and stop. Idempotent: only the first reason survives, because
    /// `openRFCOMMChannelAsync` arriving after a cancel would otherwise report a failure for a
    /// close the user asked for.
    private func fail(_ reason: String) {
        guard !closed else { return }
        closed = true
        isOpen = false
        DispatchQueue.main.async { [weak self] in self?.onClose?(reason) }
    }

    private func finish(_ reason: String?) {
        guard !closed else { return }
        closed = true
        isOpen = false
        DispatchQueue.main.async { [weak self] in self?.onClose?(reason) }
    }

    private static func describe(_ code: IOReturn) -> String {
        switch code {
        case kIOReturnSuccess: return "ok"
        case kIOReturnTimeout: return "timed out — the earbuds are asleep, in the case, or out of range"
        case kIOReturnNoDevice: return "device not found"
        case kIOReturnBusy: return "busy"
        case kIOReturnExclusiveAccess: return "another app is already using the control channel"
        case kIOReturnNotOpen: return "not open"
        default: return "IOReturn \(code)"
        }
    }
}
