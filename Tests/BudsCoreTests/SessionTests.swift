import XCTest
@testable import BudsCore

/// The session, driven entirely by a recording.
///
/// No test in this file opens a radio. That is not a convenience: a test that pages the earbuds
/// would fight the running app for the one control channel there is, and would fail for reasons
/// having nothing to do with the code under test. `ScriptedTransport` delivers exactly what the
/// RFCOMM delegate delivers, byte for byte, so the session and every decoder below it run for
/// real.
final class SessionTests: XCTestCase {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()            // Tests/BudsCoreTests
        .deletingLastPathComponent()            // Tests
        .deletingLastPathComponent()

    private func profile(_ id: String) throws -> DeviceProfile {
        let registry = try CapabilityRegistry.load(from: Self.root.appendingPathComponent("devices"))
        return try XCTUnwrap(registry.profile(id: id), "the shipped registry has no \(id)")
    }

    private func capture(_ name: String) throws -> CaptureCorpus.Capture {
        try XCTUnwrap(CaptureCorpus.frames.first { $0.name == name },
                      "the corpus has no frame called \(name)")
    }

    /// The frames the session wrote, as `cmd/type` pairs, for asserting on *requests* rather than
    /// only on replies. A recording is one direction; what the app sends is the other.
    private func sent(_ transport: ScriptedTransport) -> [String] {
        transport.written.compactMap { bytes in
            var buffer = bytes
            guard let frame = BudsProtocol.drainFrames(from: &buffer).first else { return nil }
            return String(format: "%02x/%02x", frame.cmd, frame.messageType)
        }
    }

    /// The last **setter** the session wrote.
    ///
    /// Not simply the last frame: every write is followed immediately by a read-back request, so
    /// the last thing on the wire is the getter. Reaching for `.last` and finding a getter is the
    /// mistake this helper exists to make impossible.
    private func lastWrite(_ transport: ScriptedTransport) -> BudsProtocol.Frame? {
        for bytes in transport.written.reversed() {
            var buffer = bytes
            guard let frame = BudsProtocol.drainFrames(from: &buffer).first else { continue }
            if frame.messageType == BudsProtocol.MessageType.set.rawValue { return frame }
        }
        return nil
    }

    // MARK: - The whole corpus, through the session

    /// Replay every captured frame through the real session and assert the state it ends in. This
    /// is the end-to-end claim: the frames the hardware sent produce the readings the UI draws.
    func testReplayingTheCorpusProducesTheReadingsTheCaptureRecords() throws {
        let transport = ScriptedTransport(frames: CaptureCorpus.frames)
        let session = Session(transport: transport, profile: try profile("oneplus-buds-4"))

        session.start()
        transport.deliverAll()

        XCTAssertEqual(session.phase, .ready)
        XCTAssertTrue(session.hasReadAnything)

        // Battery: left and right at 0x14 (20), and no case — which is a finding, not a gap.
        XCTAssertEqual(session.battery.left, 0x14)
        XCTAssertEqual(session.battery.right, 0x14)
        XCTAssertNil(session.battery.enclosure, "this channel never reports the case's charge")

        // Wear names all three slots, which is the only evidence the case exists.
        XCTAssertEqual(session.placement.left, .inEar)
        XCTAssertEqual(session.placement.right, .inEar)
        XCTAssertEqual(session.placement.enclosure, .inCase)
        XCTAssertTrue(session.isCaseReported)

        // The firmware string is carried verbatim, comma-separated and all.
        XCTAssertEqual(session.firmware, "1,2,138,2,2,138,3,1,01,3,2,105")
        XCTAssertEqual(session.codec, .aac)

        // The last noise frame in the corpus wins, and it is Adaptive (0x0800) — a mode with no
        // level. Auto (0x0080) came past earlier in the sequence, and its level must not survive
        // the switch: the buds are not cancelling anything at that point.
        XCTAssertEqual(session.mode, .adaptive)
        XCTAssertNil(session.ancLevel, "Auto was three frames back and is no longer true")

        // The last preset frame is the family-2 push, not the getter's reply.
        XCTAssertEqual(session.eqPreset, .bass)

        // The whole gesture table, and BassWave's level and *its* stated range.
        XCTAssertEqual(session.touchRules.count, 18)
        XCTAssertEqual(session.bassWave, 2)
        XCTAssertEqual(session.bassWaveBounds, -5...5)

        // Both linked devices, with the phone connected by the time of the getter's reply.
        XCTAssertEqual(session.linkedDevices.map(\.name), ["Shashank’s MacBook Pro", "shsxnk S23"])
        XCTAssertEqual(session.linkedDevices.first?.state, .connected)

        XCTAssertEqual(session.hasCustomEQProfile, false, "0x8122 answered a bare zero count")

        // And nothing here claims a write was applied: a recording holds replies, not our writes.
        XCTAssertTrue(session.unconfirmedWrites.isEmpty)
        XCTAssertNil(session.lastError)
    }

    /// Opening the channel sends the HELLO, then asks for everything — because the hardware
    /// pushes almost nothing on its own.
    func testOpeningSendsTheHandshakeAndThenAsksForEverything() throws {
        let transport = ScriptedTransport(frames: [])
        let session = Session(transport: transport, profile: try profile("oneplus-buds-4"))

        session.start()
        XCTAssertEqual(session.phase, .ready, "a transport that opens on start is ready at once")

        let ids = sent(transport)
        XCTAssertEqual(ids.first, "00/01", "the session HELLO is the first frame sent")
        XCTAssertEqual(ids.filter { $0 == "00/01" }.count, 1, "the HELLO is sent once")

        // Every getter the app needs, sent as a request (01) with no payload of our own.
        for expected in ["0c/01", "06/01", "09/01", "12/01", "14/01",
                         "0f/01", "24/01", "22/01", "05/01", "08/01"] {
            XCTAssertTrue(ids.contains(expected), "opening did not ask for \(expected): \(ids)")
        }

        // The ANC getter needs its argument. Sent empty, the firmware answers nothing at all.
        let anc = try XCTUnwrap(transport.written.first { bytes in
            var buffer = bytes
            return BudsProtocol.drainFrames(from: &buffer).first?.cmd == BudsProtocol.Command.anc.rawValue
        })
        var buffer = anc
        XCTAssertEqual(BudsProtocol.drainFrames(from: &buffer).first?.payload, [0x01, 0x01])
    }

    // MARK: - Writes are never optimistic

    /// The rule that matters most: pressing a control sends a frame and changes nothing on
    /// screen. Only a reply changes the displayed value — so a write the firmware ignores looks
    /// like the control snapping back, which is the truth.
    func testAWriteIsNotAppliedUntilTheDeviceReadsBack() throws {
        let transport = ScriptedTransport(frames: [])
        let session = Session(transport: transport, profile: try profile("oneplus-buds-4"))
        session.start()

        XCTAssertTrue(session.set(mode: .transparency))
        XCTAssertNil(session.mode, "the write must not set the displayed mode")
        XCTAssertEqual(session.unconfirmedWrites, [.noiseControl])

        // The mask went out, and it is the mode's own mask — the single-byte conveniences the
        // vendor app also has map to the wrong modes and are never sent.
        let write = try XCTUnwrap(lastWrite(transport), "no setter was sent")
        XCTAssertEqual(write.payload, [0x01, 0x01, 0x00, 0x01],
                       "transparency is 0x0100, little-endian")

        // Only now does the display change, and only because the device said so.
        transport.deliver(try capture("anc-reply-transparency").bytes)
        XCTAssertEqual(session.mode, .transparency)
        XCTAssertTrue(session.unconfirmedWrites.isEmpty, "the read-back confirms the write")
    }

    /// A write the firmware never answers must not stay pending forever: the app would be
    /// claiming a change it never saw. After the read-back attempts run out, the claim is
    /// dropped and the control shows the old value.
    func testAnUnansweredWriteIsGivenUpOnRatherThanLeftPending() throws {
        let transport = ScriptedTransport(frames: [])
        let session = Session(transport: transport, profile: try profile("oneplus-buds-4"))
        session.start()

        XCTAssertTrue(session.set(eqPreset: .bass))
        XCTAssertEqual(session.unconfirmedWrites, [.equalizer])
        XCTAssertNil(session.eqPreset)

        for _ in 0..<4 { session.poll() }          // four polls, no answer

        XCTAssertTrue(session.unconfirmedWrites.isEmpty, "the pending claim was never dropped")
        XCTAssertNil(session.eqPreset, "and the displayed value is still the old one — which is nil")
    }

    /// Switching to Noise cancellation has to name a cancellation level, because the mask carries
    /// both. Reusing the level the buds last reported is what makes the button a no-op for
    /// someone who already chose one on the phone.
    func testSwitchingToNoiseCancellationReusesTheReportedLevel() throws {
        let transport = ScriptedTransport(frames: [])
        let session = Session(transport: transport, profile: try profile("oneplus-buds-4"))
        session.start()

        // The device reports "cancellation, low" (0x0040).
        transport.deliver(try capture("anc-reply-nc-low").bytes)
        XCTAssertEqual(session.mode, .noiseCancellation)
        XCTAssertEqual(session.ancLevel, .low)

        XCTAssertTrue(session.set(mode: .noiseCancellation))
        let write = try XCTUnwrap(lastWrite(transport), "no setter was sent")
        XCTAssertEqual(write.payload, [0x01, 0x01, 0x40, 0x00],
                       "the level the buds reported, not High")
    }

    /// Leaving cancellation drops the level with the mode.
    ///
    /// The two fields are not independent: a level means "how hard cancellation works", so while
    /// the buds are transparent or adapting there is no honest value for it. The corpus replays
    /// cancellation on Auto and then Adaptive, which is exactly how this reads on screen as
    /// "Adaptive (Auto)" if the level is left behind.
    func testLeavingCancellationClearsTheLevelRatherThanCarryingItOver() throws {
        let transport = ScriptedTransport(frames: [])
        let session = Session(transport: transport, profile: try profile("oneplus-buds-4"))
        session.start()

        transport.deliver(try capture("anc-reply-nc-auto").bytes)
        XCTAssertEqual(session.mode, .noiseCancellation)
        XCTAssertEqual(session.ancLevel, .auto)

        transport.deliver(try capture("anc-reply-transparency").bytes)
        XCTAssertEqual(session.mode, .transparency)
        XCTAssertNil(session.ancLevel, "transparency has no cancellation level")

        // And back again: the level returns with the mode, from the device rather than from memory.
        transport.deliver(try capture("anc-reply-nc-low").bytes)
        XCTAssertEqual(session.mode, .noiseCancellation)
        XCTAssertEqual(session.ancLevel, .low)
    }

    // MARK: - The registry is the gate

    /// An uncatalogued device gets the read-only surface: every control is drawn, and not one of
    /// them sends a byte. This is the whole reason the registry exists.
    func testAnUnconfirmedDeviceHasNoWritePathAtAll() throws {
        let transport = ScriptedTransport(frames: [])
        let session = Session(transport: transport, profile: try profile("generic-family"))
        session.start()
        let before = transport.written.count

        XCTAssertFalse(session.set(mode: .off))
        XCTAssertFalse(session.set(ancLevel: .high))
        XCTAssertFalse(session.set(eqPreset: .bass))
        XCTAssertFalse(session.set(bassWave: 2))
        XCTAssertFalse(session.setGesture(.doubleTap, action: .playPause))
        XCTAssertFalse(session.find())
        XCTAssertFalse(session.stopFind())

        XCTAssertEqual(transport.written.count, before,
                       "an unwritable capability sent something: \(sent(transport).suffix(3))")
        XCTAssertNotNil(session.lastError)

        // Reading is not gated: an unknown device still answers, and this app still shows it.
        XCTAssertTrue(session.canWrite(.battery) == false)
        transport.deliver(try capture("battery-reply").bytes)
        XCTAssertEqual(session.battery.left, 0x14)
    }

    /// The BassWave bounds are the hardware's, so until the hardware has stated them there is no
    /// honest frame to send. Refusing is better than assuming another model's range.
    func testBassWaveRefusesUntilTheDeviceStatesItsRange() throws {
        let transport = ScriptedTransport(frames: [])
        let session = Session(transport: transport, profile: try profile("oneplus-buds-4"))
        session.start()

        XCTAssertNil(session.bassWaveBounds)
        XCTAssertFalse(session.set(bassWave: 2))
        XCTAssertEqual(session.lastError, "The earbuds have not reported their BassWave range yet.")

        transport.deliver(try capture("basswave-reply-2").bytes)
        XCTAssertEqual(session.bassWaveBounds, -5...5)
        XCTAssertEqual(session.bassWave, 2)

        XCTAssertTrue(session.set(bassWave: 4))
        let write = try XCTUnwrap(lastWrite(transport), "no setter was sent")
        // The bounds it was given, then the level: [min][max][level].
        XCTAssertEqual(write.payload, [0xfb, 0x05, 0x04])
    }

    /// The custom preset slot cannot be selected until a profile exists — the firmware would
    /// store it and leave the phone's own picker with no selection at all.
    func testTheCustomPresetIsRefusedUntilAProfileExists() throws {
        let transport = ScriptedTransport(frames: [])
        let session = Session(transport: transport, profile: try profile("oneplus-buds-4"))
        session.start()

        XCTAssertFalse(session.set(eqPreset: .custom), "no profile has been read yet")
        XCTAssertEqual(session.lastError, "There is no saved custom profile to select.")

        transport.deliver(try capture("custom-eq-reply").bytes)      // count 0: no profile
        XCTAssertEqual(session.hasCustomEQProfile, false)
        XCTAssertFalse(session.set(eqPreset: .custom))
    }

    /// A gesture can only be pointed at an action the firmware is known to store. The device
    /// validates nothing, so this check is the only thing standing between a menu and a value
    /// that leaves the phone's screen with no selection.
    func testAGestureMovementOutsideTheObservedSetIsRefused() throws {
        let transport = ScriptedTransport(frames: [])
        let session = Session(transport: transport, profile: try profile("oneplus-buds-4"))
        session.start()
        let before = transport.written.count

        // A slide means volume; skipping tracks is not something this hardware stores for it.
        XCTAssertFalse(session.setGesture(.slide, action: .next))
        XCTAssertEqual(transport.written.count, before)

        XCTAssertTrue(session.setGesture(.slide, action: .volumeControl))
        XCTAssertEqual(session.unconfirmedWrites, [.gestures])
        // Both earbuds, so the two sides cannot drift apart: left then right, same record.
        let write = try XCTUnwrap(lastWrite(transport), "no setter was sent")
        XCTAssertEqual(write.payload, [0x02, 0x01, 0x01, 0x05, 0x07, 0x02, 0x01, 0x05, 0x07])
    }

    // MARK: - The link, and losing it

    /// A frame split across two callbacks is one frame. The accumulation buffer is the session's,
    /// because framing is the protocol's business and not the radio's.
    func testAFragmentedFrameIsReassembled() throws {
        let transport = ScriptedTransport(frames: [])
        let session = Session(transport: transport, profile: try profile("oneplus-buds-4"))
        session.start()

        let bytes = try capture("firmware-reply").bytes
        transport.deliver(Array(bytes.prefix(6)))
        XCTAssertNil(session.firmware, "half a frame is not a frame")

        transport.deliver(Array(bytes.dropFirst(6)))
        XCTAssertEqual(session.firmware, "1,2,138,2,2,138,3,1,01,3,2,105")
    }

    /// Losing the link clears everything it was showing. A stale reading behind a dead link is
    /// the specific lie this app exists not to tell — and the case must stop being reported,
    /// because the only evidence for it was the link.
    func testClosingTheLinkClearsEveryReading() throws {
        let transport = ScriptedTransport(frames: CaptureCorpus.frames)
        let session = Session(transport: transport, profile: try profile("oneplus-buds-4"))
        session.start()
        transport.deliverAll()
        XCTAssertNotNil(session.firmware)
        XCTAssertTrue(session.isCaseReported)

        transport.close()

        XCTAssertEqual(session.phase, .closed)
        XCTAssertNil(session.firmware)
        XCTAssertNil(session.codec)
        XCTAssertNil(session.battery.left)
        XCTAssertNil(session.battery.right)
        XCTAssertNil(session.mode)
        XCTAssertNil(session.eqPreset)
        XCTAssertNil(session.bassWave)
        XCTAssertNil(session.bassWaveBounds)
        XCTAssertNil(session.hasCustomEQProfile)
        XCTAssertTrue(session.touchRules.isEmpty)
        XCTAssertTrue(session.linkedDevices.isEmpty)
        XCTAssertFalse(session.isCaseReported)
        XCTAssertFalse(session.hasReadAnything)
        // The reason is kept, because "why did it stop" is the question a person actually asks.
        XCTAssertEqual(session.lastError, "scripted transport closed")
    }

    /// A device that goes away and comes back is the normal case, not an error: after a close,
    /// `start()` opens again.
    func testASessionCanBeStartedAgainAfterItCloses() throws {
        let transport = ScriptedTransport(frames: [])
        let session = Session(transport: transport, profile: try profile("oneplus-buds-4"))
        session.start()
        transport.close()
        XCTAssertEqual(session.phase, .closed)

        session.start()
        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(sent(transport).filter { $0 == "00/01" }.count, 2, "a fresh HELLO each time")
    }

    /// A transport that cannot open reports why, and the session stays closed rather than
    /// pretending to be reading.
    func testAFailedOpenLeavesTheSessionClosedAndSaysWhy() throws {
        let transport = ScriptedTransport(frames: [], opensOnStart: false)
        let session = Session(transport: transport, profile: try profile("oneplus-buds-4"))
        session.start()
        XCTAssertEqual(session.phase, .opening)

        transport.failToOpen(reason: "device not found")
        XCTAssertEqual(session.phase, .closed)
        XCTAssertEqual(session.lastError, "device not found")
        XCTAssertFalse(session.hasReadAnything)
    }

    /// Bytes that arrive while nothing is open are dropped, not buffered for a later session:
    /// a frame from a previous link must not be decoded into this one's state.
    func testBytesFromAClosedLinkAreNotDecoded() throws {
        let transport = ScriptedTransport(frames: [])
        let session = Session(transport: transport, profile: try profile("oneplus-buds-4"))
        session.start()
        transport.close()

        transport.deliver(try capture("battery-reply").bytes)
        XCTAssertNil(session.battery.left)
    }
}
