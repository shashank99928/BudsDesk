import XCTest
@testable import BudsCore

/// The registry is where a claim about hardware becomes a control on screen, so it is the layer
/// with the most to lose from a plausible-looking edit. These tests are the teeth.
final class RegistryTests: XCTestCase {

    /// The repository root, and the two evidence directories this suite reads.
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()            // Tests/BudsCoreTests
        .deletingLastPathComponent()            // Tests
        .deletingLastPathComponent()            // the package root

    private func loadRegistry() throws -> CapabilityRegistry {
        try CapabilityRegistry.load(from: Self.root.appendingPathComponent("devices"))
    }

    // MARK: The shipped registry

    func testTheShippedRegistryLoads() throws {
        let registry = try loadRegistry()
        XCTAssertGreaterThanOrEqual(registry.profiles.count, 2,
                                    "a registry with no catalogued model and no fallback is useless")
        XCTAssertTrue(registry.profiles.contains { $0.match.fallback == true })
    }

    /// A capability marked `measured` from a capture has to name a frame that is actually in the
    /// corpus. This is the single most valuable check here: it makes "measured" unforgeable by
    /// editing prose, because the words now have to point at bytes a recording contains.
    func testMeasuredCaptureClaimsNameRealFrames() throws {
        let names = Set(CaptureCorpus.frames.map(\.name))
        let registry = try loadRegistry()

        var checked = 0
        for profile in registry.profiles {
            for (capability, spec) in profile.capabilities {
                guard spec.confidence == .measured, spec.evidence.source == .capture else { continue }
                let ref = try XCTUnwrap(spec.evidence.ref,
                                        "\(profile.id)/\(capability): measured from a capture with no ref")
                XCTAssertTrue(names.contains(ref),
                              "\(profile.id)/\(capability) cites the capture `\(ref)`, which is not in "
                              + "captures/. Either the frame was deleted or the claim is invented.")
                checked += 1
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 8, "too few measured capture claims were checked")
    }

    /// Every claim that says *something* says what it is based on — measured and inferred claims
    /// carry a note, because a note is the difference between a finding and an assertion. An
    /// `unconfirmed` capability has nothing to describe, which is what the word means, so it is
    /// allowed to say nothing.
    ///
    /// And every write path is measured. The loader enforces that too; asserting it here means a
    /// future change to the loader cannot quietly weaken the rule.
    func testMeasuredClaimsAreExplainedAndWritesAreMeasured() throws {
        let registry = try loadRegistry()
        for profile in registry.profiles {
            for (capability, spec) in profile.capabilities {
                if spec.confidence != .unconfirmed {
                    XCTAssertNotNil(spec.evidence.note ?? spec.note,
                                    "\(profile.id)/\(capability) is \(spec.confidence.label) "
                                    + "with no note saying what that rests on")
                }
                if spec.writable {
                    XCTAssertEqual(spec.confidence, .measured,
                                   "\(profile.id)/\(capability): a write path that is not measured")
                }
            }
        }
    }

    /// The fallback has to cover the whole capability surface, because it is what an uncatalogued
    /// model lands on: a capability missing there is one that can never be read from a device
    /// nobody has recorded, which is the opposite of the point.
    func testTheFallbackOffersTheWholeSurfaceButWritesNothing() throws {
        let registry = try loadRegistry()
        let fallback = try XCTUnwrap(registry.profiles.first { $0.match.fallback == true })

        for capability in Capability.allCases {
            XCTAssertNotNil(fallback.spec(capability),
                            "the fallback profile is missing \(capability.rawValue)")
        }
        for capability in Capability.allCases {
            XCTAssertFalse(fallback.canWrite(capability),
                           "the fallback offers a write path for \(capability.rawValue)")
            XCTAssertEqual(fallback.spec(capability)?.confidence, .unconfirmed,
                           "the fallback claims more than unconfirmed for \(capability.rawValue)")
        }
        // It still reads: an unknown device shows what it can, and says so honestly.
        XCTAssertTrue(fallback.offers(.battery))
        XCTAssertTrue(fallback.offers(.firmware))
        XCTAssertFalse(fallback.offers(.findMyEarbuds))
    }

    /// The catalogued model, end to end: matched by the name macOS reports, with the write paths
    /// its captures actually support and no others.
    func testTheOnePlusBudsFourProfileMatchesAndGatesWrites() throws {
        let registry = try loadRegistry()
        let service = "0000799a-d102-11e1-9b23-00025b00a5a5"

        let profile = try XCTUnwrap(
            registry.profile(advertisedName: "OnePlus Buds 4", serviceUUIDs: [service]),
            "the catalogued model did not match its own name")
        XCTAssertEqual(profile.id, "oneplus-buds-4")
        XCTAssertFalse(profile.match.fallback == true, "a name match must outrank the fallback")

        // Case-insensitive, because the OS's capitalisation is not a protocol detail.
        XCTAssertEqual(registry.profile(advertisedName: "oneplus buds 4", serviceUUIDs: [service])?.id,
                       "oneplus-buds-4")

        // The three write paths the captures support, and nothing else.
        let writable = Capability.allCases.filter { profile.canWrite($0) }
        XCTAssertEqual(Set(writable), [.noiseControl, .equalizer, .bassWave, .gestures],
                       "the write surface changed: \(writable.map(\.rawValue).sorted())")

        XCTAssertEqual(profile.noiseModes.count, 4)
        XCTAssertEqual(profile.ancLevels.count, 4)
        XCTAssertEqual(profile.eqPresets, [.balanced, .clearVocals, .bass, .custom])
        XCTAssertEqual(profile.gestures.count, 4)

        // The case has never reported, and that is recorded as a finding rather than as a gap.
        XCTAssertFalse(profile.offers(.caseBattery))
        XCTAssertEqual(profile.spec(.caseBattery)?.confidence, .measured)
    }

    /// A device that advertises the service and matches no profile lands on the fallback — and a
    /// device that does not advertise it matches nothing at all, which is what keeps this app
    /// from walking up to any paired Bluetooth device it happens to find.
    func testUnknownNamesFallBackAndForeignServicesMatchNothing() throws {
        let registry = try loadRegistry()
        let service = "0000799a-d102-11e1-9b23-00025b00a5a5"

        let unknown = try XCTUnwrap(
            registry.profile(advertisedName: "OPPO Enco Air5 Pro", serviceUUIDs: [service]))
        XCTAssertEqual(unknown.id, "generic-family")
        XCTAssertFalse(unknown.canWrite(.noiseControl))

        XCTAssertNil(registry.profile(advertisedName: "Sony WH-1000XM5",
                                      serviceUUIDs: ["0000110b-0000-1000-8000-00805f9b34fb"]),
                     "a device without the control service must match no profile")

        let noName = try XCTUnwrap(registry.profile(advertisedName: nil, serviceUUIDs: [service]))
        XCTAssertEqual(noName.id, "generic-family", "an unnamed device with the service falls back")
    }

    // MARK: The rules have teeth
    //
    // Each of these is a bug that would otherwise ship: a registry that says something the code
    // cannot back up, and a loader that shrugs. `testRulesHaveTeeth` below is the one that
    // matters most — it takes the shipped registry, breaks one thing, and asserts a named error.

    private func profile(_ capabilities: String, match: String = """
        "match": { "serviceUUIDs": ["0000799a-d102-11e1-9b23-00025b00a5a5"], "fallback": true }
        """) -> Data {
        Data("""
        { "id": "test", "model": "Test", "vendor": "Test",
          \(match),
          "capabilities": { \(capabilities) } }
        """.utf8)
    }

    private func expect(_ error: RegistryError, _ json: Data, _ what: String) {
        do {
            _ = try CapabilityRegistry.parse(json, origin: "test.json")
            XCTFail("\(what): the loader accepted it")
        } catch let thrown as RegistryError {
            XCTAssertEqual(thrown, error, what)
        } catch {
            XCTFail("\(what): threw \(error) instead of a RegistryError")
        }
    }

    func testAnUnknownCapabilityKeyIsAnError() {
        expect(.unknownCapability(profile: "test.json", key: "noiseCancellation"),
               profile("""
               "noiseCancellation": { "read": true, "writable": false, "confidence": "measured",
                 "evidence": { "source": "capture", "ref": "wear-reply" } }
               """),
               "a capability key this code does not model")
    }

    func testAValueTheCodeCannotEncodeIsAnError() {
        expect(.unknownValue(profile: "test.json", capability: "noiseControl", value: "maxAnc"),
               profile("""
               "noiseControl": { "read": true, "writable": false, "confidence": "measured",
                 "values": ["off", "maxAnc"],
                 "evidence": { "source": "capture", "ref": "anc-reply-off" } }
               """),
               "a mode value no code can encode")
    }

    func testAWritableUnconfirmedCapabilityIsAnError() {
        expect(.unconfirmedCapabilityIsWritable(profile: "test.json", capability: "noiseControl"),
               profile("""
               "noiseControl": { "read": true, "writable": true, "confidence": "unconfirmed",
                 "values": ["off"], "evidence": { "source": "none" } }
               """),
               "a write path with nothing behind it")
    }

    func testMeasuredWithoutARecordingIsAnError() {
        expect(.measuredWithoutARecording(profile: "test.json", capability: "battery",
                                          source: "apk"),
               profile("""
               "battery": { "read": true, "writable": false, "confidence": "measured",
                 "evidence": { "source": "apk", "ref": "dex:Something#get" } }
               """),
               "measured, citing the decompiled app")
    }

    func testInferredMustCiteTheReferenceAppAndUnconfirmedMustCiteNothing() {
        expect(.wrongEvidenceForConfidence(profile: "test.json", capability: "battery",
                                           confidence: "inferred", source: "capture"),
               profile("""
               "battery": { "read": true, "writable": false, "confidence": "inferred",
                 "evidence": { "source": "capture", "ref": "battery-reply" } }
               """),
               "inferred, citing a capture")

        expect(.wrongEvidenceForConfidence(profile: "test.json", capability: "battery",
                                           confidence: "unconfirmed", source: "apk"),
               profile("""
               "battery": { "read": true, "writable": false, "confidence": "unconfirmed",
                 "evidence": { "source": "apk", "ref": "dex:Something#get" } }
               """),
               "unconfirmed, citing anything at all")
    }

    func testValuesOnACapabilityThatTakesNoneIsAnError() {
        expect(.valuesOnCapabilityThatTakesNone(profile: "test.json", capability: "battery"),
               profile("""
               "battery": { "read": true, "writable": false, "confidence": "measured",
                 "values": ["left"], "evidence": { "source": "capture", "ref": "battery-reply" } }
               """),
               "a value list where none belongs")
    }

    /// A value-bearing capability with no values would draw an empty picker, which looks like a
    /// device that supports nothing rather than a registry with a hole in it.
    func testAValueBearingCapabilityWithNoValuesIsAnError() {
        expect(.missingValues(profile: "test.json", capability: "equalizer"),
               profile("""
               "equalizer": { "read": true, "writable": false, "confidence": "measured",
                 "evidence": { "source": "capture", "ref": "eq-reply-bass" } }
               """),
               "a picker with nothing in it")
    }

    func testAMissingReadOrWritableFlagIsAnError() {
        expect(.missingField(profile: "test.json", field: "capabilities.battery.writable"),
               profile("""
               "battery": { "read": true, "confidence": "measured",
                 "evidence": { "source": "capture", "ref": "battery-reply" } }
               """),
               "a capability that does not say whether it can be written")
    }

    func testNoFallbackProfileIsAnError() {
        do {
            _ = try CapabilityRegistry(profiles: [
                try CapabilityRegistry.parse(profile("""
                    "battery": { "read": true, "writable": false, "confidence": "measured",
                      "evidence": { "source": "capture", "ref": "battery-reply" } }
                    """, match: """
                    "match": { "serviceUUIDs": ["0000799a-d102-11e1-9b23-00025b00a5a5"] }
                    """), origin: "test.json"),
            ])
            XCTFail("a registry with nowhere for an unknown device to land was accepted")
        } catch let thrown as RegistryError {
            XCTAssertEqual(thrown, .noFallbackProfile)
        } catch {
            XCTFail("threw \(error) instead of a RegistryError")
        }
    }

    /// The teeth on the teeth: take the shipped registry, break one byte of one claim, and check
    /// that the failure is named rather than silent. If this test ever passes with the mutation
    /// applied, the loader has stopped enforcing it.
    func testRulesHaveTeeth() throws {
        let service = "0000799a-d102-11e1-9b23-00025b00a5a5"
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: Self.root.appendingPathComponent("devices/oneplus-buds-4.json")))
                as? [String: Any])
        var capabilities = try XCTUnwrap(object["capabilities"] as? [String: Any])
        var bassWave = try XCTUnwrap(capabilities["bassWave"] as? [String: Any])
        // The mutation: a measured write becomes an unmeasured one. Both the confidence and the
        // citation have to move together, or a different rule fires first -- which is itself the
        // behaviour we want, so the mutation is written the way a careless edit would be.
        bassWave["confidence"] = "unconfirmed"
        bassWave["evidence"] = ["source": "none"]
        capabilities["bassWave"] = bassWave
        object["capabilities"] = capabilities

        let mutated = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try CapabilityRegistry.parse(mutated, origin: "mutated.json")) { error in
            XCTAssertEqual(error as? RegistryError,
                           .unconfirmedCapabilityIsWritable(profile: "mutated.json",
                                                            capability: "bassWave"))
        }
        // And the unmutated profile loads, so the failure is the mutation and not the file.
        let registry = try loadRegistry()
        XCTAssertTrue(try XCTUnwrap(registry.profile(id: "oneplus-buds-4")).canWrite(.bassWave))
        XCTAssertNotNil(service)
    }
}
