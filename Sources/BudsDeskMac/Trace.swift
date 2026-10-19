import Foundation

/// Records every frame in both directions, so that the next capture can be made by *this* app.
///
/// This exists for one reason: the corpus of record was produced by the single-device app's trace
/// mode, and without an equivalent here the ability to measure new hardware would stay locked
/// behind a different codebase. Any model that gets a write path gets it because somebody recorded
/// it, and the recording has to start somewhere.
///
/// Off unless asked for. Set both variables to capture:
///
///     BUDSDESK_TRACE=1 BUDSDESK_TRACE_FILE=/tmp/buds4.log ./BudsDesk.app/Contents/MacOS/BudsDesk
///
/// The default path is `budsdesk-trace.log` in the working directory — deliberately a path the
/// operator chose, not one hidden in Application Support, because a trace nobody can find is a
/// trace nobody uses.
///
/// **What this writes is a log, not a capture.** A capture needs a name per frame and provenance, and
/// naming a frame is an act of interpretation: `aa 0c 00 00 0c 81 07 05 00 00 01 01 10 00` is
/// "noise cancellation, high" only because a person said so after setting it deliberately.
/// `Tools/trace-to-capture.py` does the mechanical half — copies the bytes out verbatim and stamps
/// each one with its time — and leaves the naming where it belongs.
public enum Trace {

    /// Reading the environment once at first use rather than per frame: this is consulted in the
    /// delegate callback on the RFCOMM queue, and the answer never changes during a run.
    public static let isEnabled: Bool = {
        ProcessInfo.processInfo.environment["BUDSDESK_TRACE"] == "1"
    }()

    public static let path: String = {
        let override = ProcessInfo.processInfo.environment["BUDSDESK_TRACE_FILE"] ?? ""
        if !override.isEmpty { return override }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("budsdesk-trace.log").path
    }()

    public enum Direction: String, Sendable {
        case received = "RX"
        case sent = "TX"
    }

    /// Serial, because the RFCOMM delegate callback and a caller's `write` happen on different
    /// queues and interleaved half-lines would make the log unparseable — which is worse than a
    /// lost frame, since it would look like a corrupt one.
    private static let queue = DispatchQueue(label: "dev.budsdesk.trace")

    private static var handle: FileHandle?
    private static var didFail = false
    private static let started = Date()

    /// Opens the log and writes its header now, rather than on the first frame.
    ///
    /// Called once at launch when tracing is on. The distinction matters in the field: a run with
    /// tracing on that never reaches a device leaves a log with a header and no frames, which
    /// says *nothing arrived*, whereas no log at all leaves you unable to tell whether tracing
    /// ever worked. Says where it is writing, because a trace you cannot find is one you will not
    /// read.
    public static func begin() {
        guard isEnabled else { return }
        queue.sync { _ = openIfNeeded() }
    }

    /// Append one frame. Never throws, never blocks the caller's queue: a trace that breaks the
    /// thing it is tracing has the priorities backwards.
    public static func record(_ direction: Direction, _ bytes: [UInt8]) {
        guard isEnabled, !bytes.isEmpty, !didFail else { return }
        let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        queue.async {
            guard let handle = openIfNeeded() else { return }
            let line = "\(direction.rawValue) \(stamp) \(hex)\n"
            if let data = line.data(using: .utf8) {
                do {
                    try handle.write(contentsOf: data)
                } catch {
                    // Stop rather than retry: a full disk would otherwise turn every frame into
                    // another failed write, and the first failure is the one worth reporting.
                    didFail = true
                    FileHandle.standardError.write(Data(
                        "budsdesk: trace write failed, tracing is off: \(error)\n".utf8))
                }
            }
        }
    }

    /// Opens on first use and writes the header, so a log that exists is a log with a header and a
    /// log with a header has a start time. Created with `0600`: a trace is a recording of a device
    /// somebody owns, and it does not need to be world-readable.
    private static func openIfNeeded() -> FileHandle? {
        if let handle { return handle }
        let url = URL(fileURLWithPath: path)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: nil,
                                attributes: [.posixPermissions: 0o600]) else {
                didFail = true
                FileHandle.standardError.write(Data(
                    "budsdesk: cannot create \(path), tracing is off\n".utf8))
                return nil
            }
        }
        guard let opened = try? FileHandle(forWritingTo: url) else {
            didFail = true
            FileHandle.standardError.write(Data(
                "budsdesk: cannot open \(path) for writing, tracing is off\n".utf8))
            return nil
        }
        let header = """
        # BudsDesk frame trace
        # started \(ISO8601DateFormatter().string(from: started))
        # format: <RX|TX> <epoch-millis> <hex bytes>
        # RX lines are what the earbuds sent. A capture keeps those; see
        # Tools/trace-to-capture.py, which copies them out without touching a byte.
        #
        """
        try? opened.write(contentsOf: Data((header + "\n").utf8))
        handle = opened
        FileHandle.standardError.write(Data("budsdesk: tracing frames to \(path)\n".utf8))
        return opened
    }
}
