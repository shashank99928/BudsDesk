import Foundation
import BudsCore

/// Reading a recording back in, for `--replay`.
///
/// The grammar is the one `Tools/freeze-captures.sh` writes, so a file that freezes into the
/// corpus also replays from the command line. A parser here that drifted from that one would mean
/// two answers to "what does this recording contain", which is exactly the class of drift the
/// corpus format exists to prevent.
public enum CaptureFile {

    public enum Failure: Error, LocalizedError {
        case notFound(String)
        case empty(String)
        case malformed(path: String, line: Int, why: String)

        public var errorDescription: String? {
            switch self {
            case .notFound(let path):
                return "No such recording: \(path)"
            case .empty(let path):
                return "\(path) contains no frames"
            case .malformed(let path, let line, let why):
                return "\(path):\(line): \(why)"
            }
        }
    }

    /// Load a recording from a capture directory (`capture.json` + `frames.hex`) or a bare
    /// `.hex` file. Provenance is read when the capture has it and labelled as a replay when it
    /// does not — a replay is not a hardware observation, and it must not look like one.
    public static func load(path: String) throws -> CaptureCorpus.Recording {
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw Failure.notFound(url.path)
        }

        let framesURL = isDirectory.boolValue ? url.appendingPathComponent("frames.hex") : url
        let provenance = isDirectory.boolValue
            ? provenance(in: url.appendingPathComponent("capture.json"), fallbackID: url.lastPathComponent)
            : replayProvenance(for: url)

        guard let text = try? String(contentsOf: framesURL, encoding: .utf8) else {
            throw Failure.notFound(framesURL.path)
        }
        let entries = try parse(text, path: framesURL.path)
        guard !entries.isEmpty else { throw Failure.empty(framesURL.path) }

        return CaptureCorpus.Recording(
            provenance: provenance,
            frames: entries.map {
                CaptureCorpus.Capture(name: $0.name, note: $0.note, hex: $0.hex,
                                      provenance: provenance)
            })
    }

    private struct Entry { let name: String; let note: String; let hex: String }

    /// The same rules the freeze script applies: a comment run directly above an entry becomes its
    /// note, the header block before the first entry is discarded, and an unreadable entry is a
    /// hard error rather than a silently dropped frame.
    private static func parse(_ text: String, path: String) throws -> [Entry] {
        var entries: [Entry] = []
        var note: [String] = []
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(raw)
            if line.hasPrefix("#") {
                note.append(line.dropFirst().trimmingCharacters(in: .whitespaces))
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            guard let separator = line.firstIndex(of: "=") else {
                throw Failure.malformed(path: path, line: index + 1,
                                        why: "not a comment and not an entry")
            }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces)
            let hex = line[line.index(after: separator)...].split(separator: " ").joined(separator: " ")
            guard !name.isEmpty else {
                throw Failure.malformed(path: path, line: index + 1, why: "entry with an empty name")
            }
            guard !hex.isEmpty else {
                throw Failure.malformed(path: path, line: index + 1, why: "\(name) has no bytes")
            }
            for token in hex.split(separator: " ") where UInt8(token, radix: 16) == nil {
                throw Failure.malformed(path: path, line: index + 1,
                                        why: "\(name) has a non-hex token \(token)")
            }
            entries.append(Entry(name: name, note: note.joined(separator: " ").trimmed, hex: hex))
            note.removeAll()
        }
        return entries
    }

    private static func replayProvenance(for url: URL) -> CaptureCorpus.Provenance {
        CaptureCorpus.Provenance(
            id: "replay:\(url.lastPathComponent)",
            date: "unknown",
            model: "replayed recording",
            vendor: "unknown",
            firmware: "unknown",
            firmwareSource: "not recorded — this is a replay, not a hardware observation",
            serviceName: "-", serviceUUID: "-", rfcommChannel: 0,
            tool: "BudsDesk --replay",
            host: "no radio: the frames come from a file",
            notes: "Replayed from \(url.path).")
    }

    /// Read a capture directory's `capture.json`. Unknown keys are ignored on purpose: this is a
    /// reader for a file format, not the registry, where an unknown key is a claim the code
    /// cannot back up.
    private static func provenance(in url: URL, fallbackID: String) -> CaptureCorpus.Provenance {
        let object = (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        func text(_ key: String, _ fallback: String = "unknown") -> String {
            (object[key] as? String) ?? fallback
        }
        let service = object["service"] as? [String: Any] ?? [:]
        return CaptureCorpus.Provenance(
            id: text("id", fallbackID),
            date: text("date"),
            model: text("model"),
            vendor: text("vendor"),
            firmware: text("firmware"),
            firmwareSource: text("firmwareSource"),
            serviceName: (service["name"] as? String) ?? "unknown",
            serviceUUID: (service["uuid"] as? String) ?? "unknown",
            rfcommChannel: (service["rfcommChannel"] as? Int) ?? 0,
            tool: text("tool"),
            host: text("host"),
            notes: text("notes", ""))
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespaces) }
}
