import Foundation
import BudsCore

/// The command-line modes, in the same binary as the app.
///
/// One binary, several jobs: the same code that draws the window is what a build script checks and
/// what a person runs to see what a recording actually contains. A separate build-time tool would
/// drift from the app it is meant to be checking.
///
/// Every mode here is **read-only with respect to the earbuds**, except that `--devices` opens
/// nothing and `--replay` drives a scripted transport rather than a radio. Nothing in this file
/// can page, connect to, or write to hardware.
public enum BudsDeskCLI {

    /// Run a command-line mode, or return nil to mean "launch the app".
    public static func run(_ arguments: [String]) -> Int32? {
        let args = Array(arguments.dropFirst())
        guard let command = args.first else { return nil }

        switch command {
        case "--help", "-h", "help":
            print(usage)
            return 0
        case "--version":
            print(version)
            return 0
        case "--selfcheck":
            return selfCheck(verbose: args.contains("--verbose"))
        case "--profiles":
            return listProfiles(asJSON: args.contains("--json"))
        case "--devices":
            // The one command-line mode that may touch the radio, so it is the one that opens a
            // trace. `--selfcheck` and `--profiles` deliberately do not: they are run by build.sh,
            // and a build that leaves a trace log in the working directory is a build that
            // surprised somebody.
            Trace.begin()
            return listDevices(asJSON: args.contains("--json"))
        case "--replay":
            return replay(args)
        case "--render":
            return render(args)
        case "--compare":
            return compareSnapshots(args)
        default:
            // Not a mode this binary knows. If it looks like an option, say so rather than
            // silently launching a window — a mistyped flag that opens a GUI is a bad surprise.
            if command.hasPrefix("-") {
                FileHandle.standardError.write(Data("budsdesk: unknown option \(command)\n\n".utf8))
                print(usage)
                return 2
            }
            return nil
        }
    }

    // MARK: - Modes

    /// The protocol self-check, the same code the app runs against its own shipped binary.
    ///
    /// A non-zero exit is the whole point: a build script has to be able to tell without reading
    /// the output.
    private static func selfCheck(verbose: Bool) -> Int32 {
        let result = BudsProtocol.selfCheck()
        let frames = CaptureCorpus.frameCount
        let recordings = CaptureCorpus.recordings.count
        print("protocol self-check: \(result.checks) checks, \(result.failures.count) failures")
        print("corpus:              \(frames) frames from \(recordings) recording(s)")
        for failure in result.failures { print("  ✗ \(failure)") }
        if verbose {
            for recording in CaptureCorpus.recordings {
                print("  · \(recording.provenance.id) — \(recording.provenance.model), "
                      + "firmware \(recording.provenance.firmware), "
                      + "\(recording.frames.count) frames")
            }
        }
        if result.passed {
            print("ok")
            return 0
        }
        print("FAILED")
        return 1
    }

    /// The capability registry, as the app reads it. This is the command that answers "what does
    /// this project actually claim it can do, and on what evidence".
    private static func listProfiles(asJSON: Bool) -> Int32 {
        let registry: CapabilityRegistry
        do {
            registry = try RegistryLocation.load()
        } catch {
            FileHandle.standardError.write(Data("budsdesk: \(error.localizedDescription)\n".utf8))
            return 1
        }

        if asJSON {
            let profiles = registry.profiles.map { profile -> [String: Any] in
                var capabilities: [String: Any] = [:]
                for (capability, spec) in profile.capabilities {
                    capabilities[capability.rawValue] = [
                        "read": spec.read,
                        "writable": spec.writable,
                        "confidence": spec.confidence.rawValue,
                        "evidence": [
                            "source": spec.evidence.source.rawValue,
                            "ref": spec.evidence.ref ?? "",
                            "note": spec.evidence.note ?? "",
                        ],
                        "values": spec.values ?? [],
                        "note": spec.note ?? "",
                    ]
                }
                return [
                    "id": profile.id,
                    "model": profile.model,
                    "vendor": profile.vendor,
                    "fallback": profile.match.fallback ?? false,
                    "names": profile.match.names ?? [],
                    "serviceUUIDs": profile.match.serviceUUIDs,
                    "capabilities": capabilities,
                ]
            }
            return emitJSON(["profiles": profiles])
        }

        for profile in registry.profiles {
            let fallback = profile.match.fallback == true ? "  [fallback]" : ""
            print("\(profile.id) — \(profile.model) (\(profile.vendor))\(fallback)")
            print("  matches:   \((profile.match.names ?? []).joined(separator: ", "))"
                  + "  over \(profile.match.serviceUUIDs.joined(separator: ", "))")
            for capability in Capability.allCases {
                guard let spec = profile.capabilities[capability] else { continue }
                var line = "  \(capability.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0))"
                line += spec.read ? "read " : "  ·  "
                line += spec.writable ? "write " : "      "
                line += spec.confidence.rawValue.padding(toLength: 13, withPad: " ", startingAt: 0)
                if let ref = spec.evidence.ref {
                    line += "\(spec.evidence.source.rawValue):\(ref)"
                } else {
                    line += spec.evidence.source.rawValue
                }
                if let values = spec.values, !values.isEmpty {
                    line += "  [\(values.count) values]"
                }
                print(line)
            }
            print("")
        }
        return 0
    }

    /// What is paired and speaking this protocol, and which profile each would land on.
    ///
    /// Read-only: it reads the SDP records cached at pairing time and never pages a device.
    private static func listDevices(asJSON: Bool) -> Int32 {
        let registry: CapabilityRegistry
        do {
            registry = try RegistryLocation.load()
        } catch {
            FileHandle.standardError.write(Data("budsdesk: \(error.localizedDescription)\n".utf8))
            return 1
        }

        let candidates = DeviceCatalog.candidates()
        if asJSON {
            let devices = candidates.map { device -> [String: Any] in
                let profile = registry.profile(advertisedName: device.advertisedName,
                                               serviceUUIDs: [DeviceCatalog.controlServiceUUIDString])
                return [
                    "address": device.address,
                    "advertisedName": device.advertisedName,
                    "displayName": device.displayName ?? "",
                    "profile": profile?.id ?? "",
                ]
            }
            return emitJSON(["devices": devices])
        }

        guard !candidates.isEmpty else {
            print("No paired device advertises \(DeviceCatalog.controlServiceUUIDString).")
            print("If the earbuds are paired, this is usually Bluetooth permission (System")
            print("Settings → Privacy & Security → Bluetooth) — a process without it sees an")
            print("empty list rather than an error.")
            return 0
        }
        for device in candidates {
            let profile = registry.profile(advertisedName: device.advertisedName,
                                           serviceUUIDs: [DeviceCatalog.controlServiceUUIDString])
            print("\(device.address)  \(device.advertisedName)")
            print("  profile: \(profile?.id ?? "none")"
                  + (profile?.match.fallback == true ? "  (uncatalogued: read-only)" : ""))
        }
        return 0
    }

    /// Replay a recording through the real session and the real decoders, and print what it says.
    ///
    /// This is the mode that makes the whole "the capture is the fixture" argument checkable by
    /// hand: if the app and the recording ever disagree, this prints the disagreement without a
    /// radio, an earbud, or a Mac with Bluetooth switched on.
    private static func replay(_ args: [String]) -> Int32 {
        var path: String?
        var profileID: String?
        var asJSON = false
        var index = 1
        while index < args.count {
            switch args[index] {
            case "--json": asJSON = true
            case "--profile":
                index += 1
                profileID = index < args.count ? args[index] : nil
            default:
                if path == nil { path = args[index] }
            }
            index += 1
        }
        guard let path else {
            FileHandle.standardError.write(Data("budsdesk: --replay needs a capture directory or .hex file\n".utf8))
            return 2
        }

        let registry: CapabilityRegistry
        do {
            registry = try RegistryLocation.load()
        } catch {
            FileHandle.standardError.write(Data("budsdesk: \(error.localizedDescription)\n".utf8))
            return 1
        }

        let recording: CaptureCorpus.Recording
        do {
            recording = try CaptureFile.load(path: path)
        } catch {
            FileHandle.standardError.write(Data("budsdesk: \(error.localizedDescription)\n".utf8))
            return 1
        }

        // Which profile to read it as: the named one, else whatever the recording's own model
        // matches, else the fallback. That is the same order the app uses when a device appears.
        let profile: DeviceProfile
        if let profileID {
            guard let named = registry.profile(id: profileID) else {
                FileHandle.standardError.write(Data("budsdesk: no profile called \(profileID)\n".utf8))
                return 2
            }
            profile = named
        } else {
            guard let matched = registry.profile(
                advertisedName: recording.provenance.model,
                serviceUUIDs: [DeviceCatalog.controlServiceUUIDString]) else {
                FileHandle.standardError.write(Data("budsdesk: the registry has no fallback profile\n".utf8))
                return 1
            }
            profile = matched
        }

        // The real session, over a scripted transport: same code path, no radio.
        let transport = ScriptedTransport(frames: recording.frames)
        let session = Session(transport: transport, profile: profile,
                              advertisedName: recording.provenance.model)
        session.start()
        transport.deliverAll()

        if asJSON { return emitJSON(state(of: session, recording: recording, sent: transport)) }
        print(stateText(of: session, recording: recording, sent: transport))
        return 0
    }

    // MARK: - Drawing the window

    /// The positional argument after a command, if there is one.
    private static func positional(_ args: [String], after command: String) -> String? {
        args.dropFirst().first { $0 != command && !$0.hasPrefix("-") }
    }

    /// `--render [root]`: draw the window in the states worth a picture, into the paths those
    /// surfaces declare.
    ///
    /// This is the same `DeviceWindow` the app puts on screen, driven by the recording in the
    /// corpus, so what it writes is a picture of the app rather than an illustration of it. The
    /// site shows one of these and `--compare` checks both, which is why neither is a mock-up:
    /// there is nothing here that could drift from the window without failing the build.
    private static func render(_ args: [String]) -> Int32 {
        let root = URL(fileURLWithPath: positional(args, after: "--render") ?? ".")
        return MainActor.assumeIsolated {
            do {
                for line in try Render.write(to: root) {
                    print("  \(line)")
                }
                return 0
            } catch {
                FileHandle.standardError.write(Data("budsdesk: \(error)\n".utf8))
                return 1
            }
        }
    }

    /// `--compare [root]`: the drawing above against the files in the repository. What `build.sh`
    /// runs, so a layout change that nobody looked at fails a build instead of shipping.
    ///
    /// A missing golden is a failure rather than a silent write: a build must never rewrite the
    /// thing it is supposed to be checking.
    private static func compareSnapshots(_ args: [String]) -> Int32 {
        let root = URL(fileURLWithPath: positional(args, after: "--compare") ?? ".")
        return MainActor.assumeIsolated {
            do {
                var failed = 0
                for result in try Render.compare(in: root) {
                    if result.missing {
                        failed += 1
                        print("  ?? \(result.path) has not been drawn yet; run `budsdesk --render`")
                    } else if let resized = result.resized {
                        failed += 1
                        print("  !! \(result.path) changed size: drawn "
                              + "\(Int(resized.drawn.width))×\(Int(resized.drawn.height)), golden "
                              + "\(Int(resized.golden.width))×\(Int(resized.golden.height))")
                    } else if result.passed {
                        print("  ok \(result.path) — \(result.total) pixels, "
                              + "\(result.differing) outside tolerance")
                    } else {
                        failed += 1
                        print("  !! \(result.path) — \(result.differing) of \(result.total) pixels "
                              + "differ (\(String(format: "%.2f", result.ratio * 100))%). Look at "
                              + "the two, then regenerate deliberately with `budsdesk --render`.")
                    }
                }
                return failed == 0 ? 0 : 1
            } catch {
                FileHandle.standardError.write(Data("budsdesk: \(error)\n".utf8))
                return 1
            }
        }
    }

    // MARK: - Rendering

    private static func stateText(of session: Session, recording: CaptureCorpus.Recording,
                                  sent: ScriptedTransport) -> String {
        var lines: [String] = []
        func row(_ key: String, _ value: String) {
            lines.append("  \(key.padding(toLength: 10, withPad: " ", startingAt: 0))\(value)")
        }

        lines.append("recording  \(recording.provenance.id) — \(recording.frames.count) frames")
        lines.append("  device   \(recording.provenance.model) (\(recording.provenance.vendor))")
        lines.append("  firmware \(recording.provenance.firmware)")
        lines.append("  taken    \(recording.provenance.date) by \(recording.provenance.tool)")
        lines.append("profile    \(profileTitle(session.profile, recording: recording))")
        lines.append("state")

        if let left = session.battery.left, let right = session.battery.right {
            let case_ = session.battery.enclosure.map { "\($0)%" }
                ?? (session.isCaseReported ? "has not reported a charge" : "no case reported")
            row("battery", "left \(left)%  right \(right)%  case \(case_)")
        } else {
            row("battery", "not reported")
        }

        func place(_ value: BudsCore.BudsProtocol.BudPlacement?) -> String {
            switch value {
            case .inEar?: return "in ear"
            case .inCase?: return "in case"
            case .outOfCase?: return "out of case"
            case .notPresent?: return "not present"
            case nil: return "unknown"
            }
        }
        row("wear", "left \(place(session.placement.left)) · right \(place(session.placement.right))"
            + " · case \(place(session.placement.enclosure))")
        row("noise", session.mode.map { $0.label + (session.ancLevel.map { " (\($0.label))" } ?? "") }
            ?? "not reported")
        row("equalizer", session.eqPreset?.label ?? "not reported")
        if let level = session.bassWave, let bounds = session.bassWaveBounds {
            let sign = level > 0 ? "+" : ""
            row("basswave", "\(sign)\(level)  (range \(bounds.lowerBound)…\(bounds.upperBound), from the device)")
        } else {
            row("basswave", "not reported")
        }
        row("firmware", session.firmware ?? "not reported")
        row("codec", session.codec.map { "\($0.label) (\(String(format: "0x%02x", $0.rawValue)))" }
            ?? "not reported")
        row("custom eq", session.hasCustomEQProfile.map { $0 ? "a saved profile exists" : "none saved" }
            ?? "not reported")
        row("gestures", session.touchRules.isEmpty ? "not reported"
            : "\(session.touchRules.count) records")
        if session.linkedDevices.isEmpty {
            row("linked", "not reported")
        } else {
            row("linked", session.linkedDevices.map { device in
                let state = device.state?.label ?? "unknown state"
                return "\(device.name) [\(state)\(device.isCurrentDevice ? ", current" : "")]"
            }.joined(separator: ", "))
        }
        row("pending", session.unconfirmedWrites.isEmpty ? "none"
            : session.unconfirmedWrites.map(\.rawValue).sorted().joined(separator: ", "))
        row("sent", "\(sent.written.count) frames"
            + (session.unconfirmedWrites.isEmpty ? "" : " (unanswered writes remain)"))
        if let error = session.lastError { row("last error", error) }
        return lines.joined(separator: "\n")
    }

    private static func profileTitle(_ profile: DeviceProfile, recording: CaptureCorpus.Recording) -> String {
        var title = "\(profile.id) — \(profile.model)"
        if profile.match.fallback == true, recording.provenance.model != profile.model {
            title += "  (uncatalogued: read-only)"
        }
        return title
    }

    private static func state(of session: Session, recording: CaptureCorpus.Recording,
                              sent: ScriptedTransport) -> [String: Any] {
        var state: [String: Any] = [
            "recording": recording.provenance.id,
            "frames": recording.frames.count,
            "profile": session.profile.id,
            "model": recording.provenance.model,
            "firmware": session.firmware ?? "",
            "sent": sent.written.count,
            "pendingWrites": session.unconfirmedWrites.map(\.rawValue).sorted(),
        ]
        if let left = session.battery.left { state["batteryLeft"] = left }
        if let right = session.battery.right { state["batteryRight"] = right }
        if let enclosure = session.battery.enclosure { state["batteryCase"] = enclosure }
        state["caseReported"] = session.isCaseReported
        state["mode"] = session.mode?.rawValue ?? ""
        state["ancLevel"] = session.ancLevel?.rawValue ?? ""
        state["eqPreset"] = session.eqPreset?.rawValue ?? ""
        state["codec"] = session.codec?.label ?? ""
        state["customEQProfile"] = session.hasCustomEQProfile ?? false
        state["bassWave"] = session.bassWave ?? 0
        if let bounds = session.bassWaveBounds {
            state["bassWaveRange"] = [bounds.lowerBound, bounds.upperBound]
        }
        state["gestureRecords"] = session.touchRules.count
        state["linkedDevices"] = session.linkedDevices.map { ["name": $0.name, "connected": $0.state == .connected] }
        if let error = session.lastError { state["lastError"] = error }
        return state
    }

    private static func emitJSON(_ object: Any) -> Int32 {
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.prettyPrinted, .sortedKeys]) else {
            FileHandle.standardError.write(Data("budsdesk: could not encode JSON\n".utf8))
            return 1
        }
        FileHandle.standardOutput.write(data)
        print("")
        return 0
    }

    // MARK: - Text

    /// The version this binary is.
    ///
    /// Read from the bundle rather than written here: the plist is what Get Info shows and what
    /// the site advertises, and a third copy in a Swift literal is a third thing to forget. A
    /// `swift run` has no bundle, so the fallback below is the one place a version is typed —
    /// and `DocumentationTests` checks that it agrees with the plist.
    static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? sourceFallbackVersion
    }

    /// The version to report when there is no bundle to ask.
    static let sourceFallbackVersion = "0.1.1"

    static let usage = """
    budsdesk — a macOS app for OPPO / OnePlus / realme TWS earbuds, by measurement.

    usage:
      budsdesk                       open the app
      budsdesk --devices [--json]    list paired devices speaking this protocol, and the
                                     capability profile each one would land on
      budsdesk --profiles [--json]   print the capability registry, with the evidence behind
                                     every claim
      budsdesk --replay <path> [--profile <id>] [--json]
                                     replay a recording (a captures/<id>/ directory or a .hex
                                     file) through the real session and decoders, and print
                                     what it says. No radio is touched.
      budsdesk --render [root]       draw the window in the states worth a picture, driven by
                                     the recording in the corpus, and write each one to the
                                     path it declares. No radio is touched.
      budsdesk --compare [root]      draw the same surfaces and compare them with the files in
                                     the repository; exits non-zero on any difference
      budsdesk --selfcheck [--verbose]
                                     run the protocol self-check over the frozen corpus and
                                     exit non-zero on any failure
      budsdesk --version
      budsdesk --help

    The earbuds' firmware-update channel is out of scope permanently and is never opened.
    See SCOPE.md.
    """
}
