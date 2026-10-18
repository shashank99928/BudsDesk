import Foundation

// MARK: - Confidence
//
// Every capability on every model carries one of these three words, and the word is what the UI
// is allowed to do with it. The distinction is not decoration: it is the difference between a
// control that works and a control that lies.

/// How much is actually known about a capability on a model.
public enum Confidence: String, Codable, Sendable, CaseIterable {
    /// Watched on the hardware: a capture shows the request and the reply, or a hardware loop
    /// shows the write and its read-back.
    case measured
    /// Read out of the reference app's own code but not confirmed against hardware.
    case inferred
    /// Exists in the protocol family; nothing shows it working on this model.
    case unconfirmed

    public var label: String {
        switch self {
        case .measured: return "measured"
        case .inferred: return "inferred"
        case .unconfirmed: return "unconfirmed"
        }
    }
}

// MARK: - Capability

/// A feature the protocol family can have.
///
/// This is a closed set on purpose. A `devices/*.json` that names a capability not in this enum
/// is a **load error**, not a line that is quietly skipped — a typo in a registry key would
/// otherwise disable a feature silently, and a silently disabled feature is indistinguishable
/// from an unsupported one.
public enum Capability: String, Codable, Sendable, CaseIterable {
    /// Connect and read the device's state at all.
    case stateRead
    /// The buds' own charge levels.
    case battery
    /// The charging case's charge. Kept separate from `battery` because it is separate on the
    /// wire: a model can report the buds and never the case.
    case caseBattery
    /// Which buds are in ear, in case, or away.
    case wear
    /// Noise cancellation modes and levels, and the passthrough modes.
    case noiseControl
    /// Sound Master equalizer presets.
    case equalizer
    /// The BassWave level. Its bounds are *not* in the registry: the getter reports the
    /// hardware's own range, and a registry that restated it would be a second, staler copy.
    case bassWave
    /// Remapping a touch gesture to an action.
    case gestures
    /// The multi-connect (multipoint) device table, and whether it can be changed.
    case multipoint
    /// Ringing a bud to find it.
    case findMyEarbuds
    /// The version string the hardware reports. Read-only by nature.
    case firmware
    /// The audio codec the link is using. Read-only: the vendor setter exists but writing a
    /// codec changes the *phone's* link, not the Mac's, and this app offers no such control.
    case codec

    public var title: String {
        switch self {
        case .stateRead: return "Device state"
        case .battery: return "Battery"
        case .caseBattery: return "Case battery"
        case .wear: return "Wear detection"
        case .noiseControl: return "Noise control"
        case .equalizer: return "Equalizer"
        case .bassWave: return "BassWave"
        case .gestures: return "Gestures"
        case .multipoint: return "Multi-connect"
        case .findMyEarbuds: return "Find my earbuds"
        case .firmware: return "Firmware"
        case .codec: return "Codec"
        }
    }

    /// The values a `values` array may name for this capability, or `nil` when the capability has
    /// no enumerated values. A registry listing anything outside this set fails to load, so a
    /// model cannot be configured to offer a mode the codec cannot encode.
    var allowedValues: Set<String>? {
        switch self {
        case .noiseControl:
            return Set(NoiseMode.allCases.map(\.rawValue) + ANCLevel.allCases.map(\.rawValue))
        case .equalizer:
            return Set(EQPreset.allCases.map(\.rawValue))
        case .gestures:
            return Set(BudsProtocol.MediaGesture.allCases.map(\.registryName))
        default:
            return nil
        }
    }

    /// Whether a `values` array is meaningful here. A capability that takes no values must not
    /// carry one, for the same reason an unknown capability must not load.
    var takesValues: Bool { allowedValues != nil }
}

extension BudsProtocol.MediaGesture {
    /// The name this gesture is written as in `devices/*.json`.
    ///
    /// The wire raw value is a `UInt8`, and a registry keyed by numbers would be unreadable to
    /// the person editing it — which is the one thing the registry has to be, since adding a
    /// model is meant to be a file and not a build. So the JSON uses case names, and this is the
    /// single place the two are tied together.
    public var registryName: String {
        switch self {
        case .doubleTap: return "doubleTap"
        case .tripleTap: return "tripleTap"
        case .touchAndHold: return "touchAndHold"
        case .slide: return "slide"
        }
    }

    public init?(registryName: String) {
        guard let match = BudsProtocol.MediaGesture.allCases
            .first(where: { $0.registryName == registryName }) else { return nil }
        self = match
    }
}

// MARK: - Evidence

/// Where a claim came from. A confidence word is worthless without this, so it is not optional.
public struct Evidence: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable {
        /// A recording committed under `captures/`. The ref names a frame in it.
        case capture
        /// The reference app's decompiled code. The ref names a class and method.
        case apk
        /// A run of `Tools/hardware-loop.md` on real hardware. The ref names the model's
        /// firmware string, or the log committed for that run.
        case hardwareLoop = "hardware-loop"
        /// Nothing. Only legal for `unconfirmed`, because an unconfirmed claim cites nothing.
        case none
    }

    public let source: Source
    /// The specific thing being cited: a capture frame name, a `dex:Class#method`, or a log.
    public let ref: String?
    /// What the citation shows, in words, for a reader who will not open it.
    public let note: String?
}

// MARK: - A capability's specification on one model

public struct CapabilitySpec: Codable, Sendable, Equatable {
    /// Whether the device reports this at all. `read: false` means the family has it and this
    /// model does not report it — which is a finding, not a gap, and is why it is allowed to be
    /// `measured`.
    public let read: Bool
    /// Whether this app offers a write path. Only ever true at `measured` confidence; see
    /// `RegistryError.unconfirmedCapabilityIsWritable`.
    public let writable: Bool
    public let confidence: Confidence
    public let evidence: Evidence
    /// The subset of the capability's enum this model offers, in the order the UI should draw it.
    public let values: [String]?
    public let note: String?
}

// MARK: - A model

public struct DeviceProfile: Sendable, Equatable {
    public struct Match: Codable, Sendable, Equatable {
        /// Names to match exactly, case-insensitively, against the name the OS reports.
        public let names: [String]?
        /// Name prefixes to match, case-insensitively. For a family whose names carry a
        /// generation suffix in some regions.
        public let namePrefixes: [String]?
        /// SDP service UUIDs the device must advertise. Every member of the family advertises
        /// the control service, so this alone is too broad to identify a model — it is the gate,
        /// not the key.
        public let serviceUUIDs: [String]
        /// The profile to use when nothing more specific matches. Exactly one profile in a
        /// registry may set this, and a test asserts it.
        public let fallback: Bool?
    }

    public let id: String
    public let model: String
    public let vendor: String
    public let match: Match
    public let capabilities: [Capability: CapabilitySpec]
    public let notes: String?

    /// The spec for a capability, or nil when this model does not have it at all.
    public func spec(_ capability: Capability) -> CapabilitySpec? { capabilities[capability] }

    /// Whether the UI should draw a control for this capability. Presence is what gates
    /// drawing — a capability the model does not have is *absent*, and absence is what makes a
    /// control disappear rather than appear disabled.
    public func offers(_ capability: Capability) -> Bool { capabilities[capability]?.read == true }

    /// Whether this app may write. Requires both an offered capability and a spec that was
    /// measured with a write path — unconfirmed never writes.
    public func canWrite(_ capability: Capability) -> Bool {
        guard let spec = capabilities[capability] else { return false }
        return spec.writable && spec.confidence == .measured
    }

    /// The values a capability offers, in registry order, filtered to the enum cases this code
    /// actually models. Loading already rejected anything outside the enum, so the filter is
    /// belt-and-braces for a hand-edited file.
    public func values(_ capability: Capability) -> [String] { capabilities[capability]?.values ?? [] }

    public var noiseModes: [NoiseMode] {
        values(.noiseControl).compactMap(NoiseMode.init(rawValue:))
    }

    public var ancLevels: [ANCLevel] {
        values(.noiseControl).compactMap(ANCLevel.init(rawValue:))
    }

    public var eqPresets: [EQPreset] {
        values(.equalizer).compactMap(EQPreset.init(rawValue:))
    }

    public var gestures: [BudsProtocol.MediaGesture] {
        values(.gestures).compactMap(BudsProtocol.MediaGesture.init(registryName:))
    }

    /// How this profile is described in a UI that has to be honest about what it is reading.
    public var provenanceLine: String { "\(vendor) \(model) · profile \(id)" }
}

// MARK: - Errors

/// A registry problem is a build failure, never a runtime shrug. Every case names the profile
/// and the capability, because "failed to load the registry" is not a usable error message.
public enum RegistryError: Error, LocalizedError, Equatable {
    case notAProfile(String)
    case missingField(profile: String, field: String)
    case unknownCapability(profile: String, key: String)
    case unknownValue(profile: String, capability: String, value: String)
    case valuesOnCapabilityThatTakesNone(profile: String, capability: String)
    case missingValues(profile: String, capability: String)
    case measuredWithoutARecording(profile: String, capability: String, source: String)
    case wrongEvidenceForConfidence(profile: String, capability: String,
                                    confidence: String, source: String)
    case unconfirmedCapabilityIsWritable(profile: String, capability: String)
    case noFallbackProfile
    case moreThanOneFallbackProfile([String])
    case duplicateProfileID(String)
    case unreadableDirectory(String)

    public var errorDescription: String? {
        switch self {
        case .notAProfile(let path):
            return "\(path) is not a device profile: it has no `capabilities` object"
        case .missingField(let profile, let field):
            return "\(profile): the profile is missing `\(field)`"
        case .unknownCapability(let profile, let key):
            return "\(profile): `\(key)` is not a capability this code models. A key that loads "
                 + "and does nothing is worse than one that fails: it looks supported."
        case .unknownValue(let profile, let capability, let value):
            return "\(profile): \(capability) offers the value `\(value)`, which no code here can "
                 + "encode or draw."
        case .valuesOnCapabilityThatTakesNone(let profile, let capability):
            return "\(profile): \(capability) takes no values, but one is listed"
        case .missingValues(let profile, let capability):
            return "\(profile): \(capability) is a value-bearing capability with no `values`"
        case .measuredWithoutARecording(let profile, let capability, let source):
            return "\(profile): \(capability) is `measured` but cites `\(source)`; only a capture "
                 + "or a hardware loop counts as measured"
        case .wrongEvidenceForConfidence(let profile, let capability, let confidence, let source):
            return "\(profile): \(capability) is `\(confidence)` but cites `\(source)`. Measured "
                 + "means a capture or a hardware loop; inferred means the reference app's code; "
                 + "unconfirmed means nothing, which is what the word means."
        case .unconfirmedCapabilityIsWritable(let profile, let capability):
            return "\(profile): \(capability) is writable at `unconfirmed` confidence. A write "
                 + "path with nothing behind it is the one thing this registry exists to prevent."
        case .noFallbackProfile:
            return "no profile sets `match.fallback`: an unknown device would have nowhere to land"
        case .moreThanOneFallbackProfile(let ids):
            return "more than one fallback profile: \(ids.sorted().joined(separator: ", "))"
        case .duplicateProfileID(let id):
            return "two profiles share the id `\(id)`"
        case .unreadableDirectory(let path):
            return "cannot read the registry at \(path)"
        }
    }
}

// MARK: - The registry

/// Every known model, loaded from `devices/*.json`.
///
/// The JSON is the source of truth and is read at runtime, deliberately: a model that is not in
/// the registry still connects, and adding one is a file, not a build.
public struct CapabilityRegistry: Sendable {
    public let profiles: [DeviceProfile]

    public init(profiles: [DeviceProfile]) throws {
        var seen: Set<String> = []
        for profile in profiles {
            guard seen.insert(profile.id).inserted else {
                throw RegistryError.duplicateProfileID(profile.id)
            }
        }
        let fallbacks = profiles.filter { $0.match.fallback == true }
        if fallbacks.isEmpty { throw RegistryError.noFallbackProfile }
        if fallbacks.count > 1 {
            throw RegistryError.moreThanOneFallbackProfile(fallbacks.map(\.id))
        }
        self.profiles = profiles
    }

    /// Load every `*.json` in a directory. Order is the file name order, so the result is
    /// deterministic and a diff of two registries is readable.
    public static func load(from directory: URL) throws -> CapabilityRegistry {
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
        } catch {
            throw RegistryError.unreadableDirectory(directory.path)
        }
        let files = contents
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var profiles: [DeviceProfile] = []
        for file in files {
            profiles.append(try parse(Data(contentsOf: file), origin: file.lastPathComponent))
        }
        return try CapabilityRegistry(profiles: profiles)
    }

    /// Parse one profile, rejecting anything that would let the UI claim more than the evidence.
    public static func parse(_ data: Data, origin: String = "(data)") throws -> DeviceProfile {
        let object: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw RegistryError.notAProfile(origin)
            }
            object = parsed
        } catch let error as RegistryError {
            throw error
        } catch {
            throw RegistryError.notAProfile(origin)
        }

        func string(_ key: String, _ required: Bool = false) throws -> String? {
            if let value = object[key] as? String { return value }
            if required { throw RegistryError.missingField(profile: origin, field: key) }
            return nil
        }

        guard let id = try string("id", true),
              let model = try string("model", true),
              let vendor = try string("vendor", true) else {
            throw RegistryError.missingField(profile: origin, field: "id/model/vendor")
        }
        guard let capObject = object["capabilities"] as? [String: Any] else {
            throw RegistryError.notAProfile(origin)
        }
        guard let matchObject = object["match"] as? [String: Any],
              let serviceUUIDs = matchObject["serviceUUIDs"] as? [String],
              !serviceUUIDs.isEmpty else {
            throw RegistryError.missingField(profile: origin, field: "match.serviceUUIDs")
        }

        var capabilities: [Capability: CapabilitySpec] = [:]
        for (key, raw) in capObject {
            guard let capability = Capability(rawValue: key) else {
                throw RegistryError.unknownCapability(profile: origin, key: key)
            }
            guard let entry = raw as? [String: Any] else {
                throw RegistryError.missingField(profile: origin, field: "capabilities.\(key)")
            }
            guard let read = entry["read"] as? Bool else {
                throw RegistryError.missingField(profile: origin, field: "capabilities.\(key).read")
            }
            guard let writable = entry["writable"] as? Bool else {
                throw RegistryError.missingField(
                    profile: origin, field: "capabilities.\(key).writable")
            }
            guard let confidenceRaw = entry["confidence"] as? String,
                  let confidence = Confidence(rawValue: confidenceRaw) else {
                throw RegistryError.missingField(
                    profile: origin, field: "capabilities.\(key).confidence")
            }
            guard let evidenceObject = entry["evidence"] as? [String: Any],
                  let sourceRaw = evidenceObject["source"] as? String,
                  let source = Evidence.Source(rawValue: sourceRaw) else {
                throw RegistryError.missingField(
                    profile: origin, field: "capabilities.\(key).evidence.source")
            }
            let evidence = Evidence(source: source,
                                    ref: evidenceObject["ref"] as? String,
                                    note: evidenceObject["note"] as? String)
            let values = entry["values"] as? [String]

            // A capability's own shape first: a value list where none belongs, or none where one
            // does, is a mistake in the file and not a capability that is merely unknown.
            if let values, !capability.takesValues {
                throw RegistryError.valuesOnCapabilityThatTakesNone(
                    profile: origin, capability: key)
            }
            if capability.takesValues, values == nil {
                throw RegistryError.missingValues(profile: origin, capability: key)
            }
            if let values, let allowed = capability.allowedValues {
                for value in values where !allowed.contains(value) {
                    throw RegistryError.unknownValue(
                        profile: origin, capability: key, value: value)
                }
            }

            // Then the claim's strength, as one rule per confidence word: a claim must cite
            // exactly the kind of thing that can support it. This is what stops a
            // plausible-looking registry from shipping a write path with nothing behind it.
            switch confidence {
            case .measured:
                if source != .capture && source != .hardwareLoop {
                    throw RegistryError.measuredWithoutARecording(
                        profile: origin, capability: key, source: source.rawValue)
                }
            case .inferred:
                if source != .apk {
                    throw RegistryError.wrongEvidenceForConfidence(
                        profile: origin, capability: key,
                        confidence: confidence.rawValue, source: source.rawValue)
                }
            case .unconfirmed:
                if source != .none {
                    throw RegistryError.wrongEvidenceForConfidence(
                        profile: origin, capability: key,
                        confidence: confidence.rawValue, source: source.rawValue)
                }
            }
            if writable && confidence != .measured {
                throw RegistryError.unconfirmedCapabilityIsWritable(
                    profile: origin, capability: key)
            }

            capabilities[capability] = CapabilitySpec(
                read: read, writable: writable, confidence: confidence,
                evidence: evidence, values: values, note: entry["note"] as? String)
        }

        let match = DeviceProfile.Match(
            names: matchObject["names"] as? [String],
            namePrefixes: matchObject["namePrefixes"] as? [String],
            serviceUUIDs: serviceUUIDs,
            fallback: matchObject["fallback"] as? Bool)

        return DeviceProfile(id: id, model: model, vendor: vendor, match: match,
                             capabilities: capabilities, notes: object["notes"] as? String)
    }

    /// The profile for a device the OS has shown us.
    ///
    /// Order of precedence, and why: an exact name match is what the user sees and is the only
    /// signal a model can be identified by without asking the device anything; a prefix catches
    /// the regional generation suffixes; and the fallback catches everything else, so an
    /// uncatalogued model gets the read-only surface rather than nothing.
    public func profile(advertisedName: String?, serviceUUIDs: [String]) -> DeviceProfile? {
        let uuidSet = Set(serviceUUIDs.map { $0.lowercased() })
        let candidates = profiles.filter { profile in
            !uuidSet.isDisjoint(with: profile.match.serviceUUIDs.map { $0.lowercased() })
        }
        let name = advertisedName?.lowercased()

        if let name {
            if let exact = candidates.first(where: { profile in
                profile.match.names?.contains { $0.lowercased() == name } == true
            }) { return exact }
            if let prefixed = candidates.first(where: { profile in
                profile.match.namePrefixes?.contains { name.hasPrefix($0.lowercased()) } == true
            }) { return prefixed }
        }
        return candidates.first { $0.match.fallback == true }
    }

    /// The profile with a given id, for tests and for `--profile`.
    public func profile(id: String) -> DeviceProfile? {
        profiles.first { $0.id == id }
    }
}
