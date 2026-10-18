import Foundation
import BudsCore

/// Where the capability registry lives at runtime.
///
/// The registry is read from disk rather than compiled in, deliberately: adding a model is meant
/// to be a file and not a build. That makes *where* the file is a real question, so the search is
/// written down rather than assumed.
public enum RegistryLocation {

    /// The first place that actually contains JSON profiles.
    ///
    /// In order:
    /// 1. `BUDSDESK_DEVICES` — an override, for a registry that is being edited or tested.
    /// 2. The app bundle's `Resources/devices` — how a shipped app finds its own registry.
    /// 3. `devices/` beside the executable, and one level up — how a `swift run` finds it.
    /// 4. `devices/` in the working directory — how a developer's shell finds it.
    public static func devicesDirectory() -> URL? {
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["BUDSDESK_DEVICES"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("devices"))
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .deletingLastPathComponent()
        candidates.append(executable.appendingPathComponent("devices"))
        candidates.append(executable.deletingLastPathComponent()
            .appendingPathComponent("Resources/devices"))
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("devices"))
        return candidates.first { hasProfiles($0) }
    }

    private static func hasProfiles(_ directory: URL) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return false }
        return contents.contains { $0.pathExtension == "json" }
    }

    /// Load the registry, or say precisely why not. A missing registry is not something an app
    /// can shrug past: without it there is no profile, no capability and nothing to draw.
    public static func load() throws -> CapabilityRegistry {
        guard let directory = devicesDirectory() else {
            throw RegistryUnavailable.notFound(searched: searchDescription)
        }
        return try CapabilityRegistry.load(from: directory)
    }

    public static var searchDescription: String {
        let executable = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .deletingLastPathComponent().path
        return "BUDSDESK_DEVICES, the app bundle's Resources/devices, \(executable)/devices, "
             + "and ./devices"
    }

    public enum RegistryUnavailable: Error, LocalizedError {
        case notFound(searched: String)

        public var errorDescription: String? {
            switch self {
            case .notFound(let searched):
                return "No capability registry found. Looked in: \(searched)."
            }
        }
    }
}
