import AppKit
import Combine
import Foundation
import BudsCore

/// The host: discovery, the clock, and the one `Session` there is.
///
/// `Session` owns no timer on purpose (see `DECISIONS.md` D6), so something has to own one. That
/// something is this class, and it is deliberately the *only* place in the app with a clock in it.
///
/// It also carries the on-disk profile choice and the reason nothing is showing, because "no
/// earbuds found" and "the earbuds are found but asleep" are different sentences and a person
/// needs to see the right one.
@MainActor
final class AppModel: ObservableObject {

    /// How this model is being driven.
    ///
    /// The app runs `.live` and only `.live`. The other two exist so the window can be drawn
    /// without a radio — `--render` uses them to take the pictures the site shows and the ones the
    /// build compares against. Everything below the transport is the app's own code either way:
    /// the same `Session`, the same profile from the same registry, the same views. Only discovery
    /// and the clock are replaced, which is what makes a picture taken this way worth anything
    /// more than a mock-up.
    enum Scene {
        /// Discovery, a clock and a real RFCOMM link.
        case live
        /// A recording, replayed through the real session at a fixed time.
        case replay(Replay)
        /// Looking for paired earbuds and finding none: what a first launch with the buds away
        /// shows, and the only state that needs no recording to be honest about.
        case away
    }

    /// Everything a replay needs, and nothing else.
    struct Replay {
        let recording: CaptureCorpus.Recording
        let profile: DeviceProfile
        /// Stands in for the unit the recording was taken from. Its address is never drawn —
        /// nothing in the window shows one — so it says that it is a stand-in rather than
        /// borrowing a real unit's address.
        let device: PairedBudDevice
        /// The clock. Fixed, so two drawings of one recording are the same picture.
        let now: () -> Date
    }

    // MARK: Published state

    /// Bumped whenever the session's state changes, so SwiftUI re-reads the session. The session is
    /// a plain class with `private(set)` state on purpose: it has no view framework in it, which is
    /// what lets it be tested and shared with a future Windows or Linux host.
    @Published private(set) var revision = 0
    @Published private(set) var status = "Looking for earbuds…"
    @Published private(set) var problem: String?
    @Published private(set) var candidates: [PairedBudDevice] = []
    @Published private(set) var profile: DeviceProfile?
    @Published private(set) var registryDescription = "registry not loaded"
    @Published private(set) var activity: [String] = []

    /// The live session, if there is a link or an attempt in flight.
    private(set) var session: Session?
    /// The device the session is talking to.
    private(set) var device: PairedBudDevice?

    // MARK: Derived

    var isReady: Bool { session?.isReady == true }
    var isOpening: Bool { session?.phase == .opening }
    /// Whether the earbuds are paired and advertising the control service. This is what the
    /// menu-bar item hangs on: no device, no item.
    var isPresent: Bool { !candidates.isEmpty }
    /// True when the device is present but the link is not up, which is the state a person needs
    /// words for rather than an empty panel.
    var isAway: Bool { !isPresent }

    /// Whether the capability registry loaded.
    ///
    /// "No registry" and "no earbuds found" are different sentences, and the window has to be able
    /// to tell them apart: the first is a broken install and the second is an ordinary first
    /// launch. Drawing both with the words for the first is the bug the `away` golden caught.
    var hasRegistry: Bool { registry != nil }

    // MARK: Private

    private var registry: CapabilityRegistry?
    private var transport: (any Transport)?
    private var ticker: Timer?
    private var nextAttempt = Date.distantPast
    private var isConnecting = false

    /// How this model was built and what its clock is. `Session` owns no timer (D6) and this class
    /// is the only clock in the app, so a drawing gets a clock of its own here rather than reaching
    /// for `Date()` in the middle of a render.
    private let scene: Scene
    private let now: () -> Date

    private static let tick: TimeInterval = 2
    private static let retryInterval: TimeInterval = 6

    init(scene: Scene = .live) {
        self.scene = scene
        switch scene {
        case .live, .away: now = Date.init
        case .replay(let replay): now = replay.now
        }

        loadRegistry()

        switch scene {
        case .live:
            adoptPinnedAddressIfRequested()
            let ticker = Timer.scheduledTimer(withTimeInterval: Self.tick, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.onTick() }
            }
            // `.common` so the tick keeps running while a menu is open or a list is scrolling: the
            // default mode stops during menu tracking, which is exactly when a stale reading is most
            // visible.
            RunLoop.main.add(ticker, forMode: .common)
            self.ticker = ticker
            onTick()

        case .away:
            candidates = []
            status = "No earbuds found. Pair them in System Settings → Bluetooth."
            // See `replayInto`: a drawing must not carry the directory layout of the machine that
            // drew it. This is the same reason, for the state that needs no recording.
            registryDescription = plainRegistryDescription + " · no device found yet"

        case .replay(let replay):
            replayInto(replay)
        }
    }

    deinit {
        ticker?.invalidate()
    }

    // MARK: - Replay

    /// Drive the real session from a recording, with no radio and no ticker.
    ///
    /// The window a person sees here is the app's window: `DeviceWindow` reading a `Session` that
    /// parsed the same frames the hardware sent. What makes it safe to publish is that the footer
    /// says which recording it is, so the picture carries its own provenance instead of pretending
    /// a unit is on the desk.
    private func replayInto(_ replay: Replay) {
        candidates = [replay.device]
        device = replay.device
        profile = replay.profile

        // The live description names the directory the registry was read from, which is a fact
        // about the machine that drew it rather than about the app. A recording id is a fact about
        // the picture, so a drawing says that instead.
        registryDescription = plainRegistryDescription + " · replaying \(replay.recording.provenance.id)"

        note("Replaying \(replay.recording.provenance.id) — \(replay.recording.frames.count) frames, "
             + "\(replay.recording.provenance.model), taken \(replay.recording.provenance.date).")

        let transport = ScriptedTransport(frames: replay.recording.frames)
        let session = Session(transport: transport, profile: replay.profile,
                              advertisedName: replay.device.advertisedName,
                              log: { [weak self] line in
                                  Task { @MainActor in self?.note(line) }
                              })
        session.onChange = { [weak self] in
            Task { @MainActor in self?.sessionChanged() }
        }
        self.transport = transport
        self.session = session
        session.start()
        transport.deliverAll()
        sessionChanged()
    }

    // MARK: - Registry

    private func loadRegistry() {
        do {
            let registry = try RegistryLocation.load()
            self.registry = registry
            let measured = registry.profiles.filter { $0.match.fallback != true }
            registryDescription = "\(measured.count) catalogued model"
                + (measured.count == 1 ? "" : "s")
                + (RegistryLocation.devicesDirectory().map { " · \($0.path)" } ?? "")
        } catch {
            registry = nil
            problem = error.localizedDescription
            status = "The capability registry could not be read. Reinstalling BudsDesk restores it."
        }
    }

    /// What the footer says about the registry, without naming the directory it was read from.
    ///
    /// A drawing must not carry the machine's directory layout: a visitor does not need it, and two
    /// machines have to draw the same picture. The live app still says where the registry was read
    /// from, because that is a real thing a person may want to look at.
    private var plainRegistryDescription: String {
        let measured = registry?.profiles.filter { $0.match.fallback != true }.count ?? 0
        return "\(measured) catalogued model" + (measured == 1 ? "" : "s")
    }

    /// `BUDSDESK_ADDRESS` names one device, for someone with more than one pair of these earbuds.
    private var pinnedAddress: String? {
        let value = ProcessInfo.processInfo.environment["BUDSDESK_ADDRESS"]
        return (value?.isEmpty == false) ? value : nil
    }

    private func adoptPinnedAddressIfRequested() {
        guard pinnedAddress != nil else { return }
        note("Pinned to \(pinnedAddress!) by BUDSDESK_ADDRESS.")
    }

    // MARK: - The tick

    private func onTick() {
        guard registry != nil else { return }
        refreshCandidates()

        guard isPresent else {
            if session != nil {
                note("The earbuds are no longer paired or in range.")
                disconnect()
            }
            status = "No earbuds found. Pair them in System Settings → Bluetooth."
            return
        }

        if session == nil, !isConnecting, now() >= nextAttempt {
            connect()
        } else if isReady {
            session?.poll()
        }

        updateStatus()
    }

    private func refreshCandidates() {
        let all = DeviceCatalog.candidates()
        let filtered = pinnedAddress.map { pinned in
            all.filter { $0.address.uppercased() == pinned.uppercased() }
        } ?? all
        // The display name comes from the Bluetooth daemon, which only `system_profiler` reports,
        // and only for the device that is actually being talked to: asking for every candidate on
        // every tick would spawn a process every two seconds for names nothing is showing.
        candidates = filtered.map { device in
            var device = device
            if self.device?.address == device.address { device.displayName = self.device?.displayName }
            return device
        }
    }

    // MARK: - Connecting

    private func connect() {
        guard let registry else { return }
        let address = device?.address ?? candidates.first?.address
        guard let address else { return }
        let candidate = candidates.first { $0.address == address } ?? candidates[0]

        // The profile is chosen by what the device says it is, and the fallback catches everything
        // else. Nothing here branches on a model name.
        guard let profile = registry.profile(
            advertisedName: candidate.advertisedName,
            serviceUUIDs: [DeviceCatalog.controlServiceUUIDString]) else {
            problem = "No profile matched, and the registry has no fallback for this device. "
                    + "Update BudsDesk, or pair a model it knows."
            return
        }
        self.profile = profile

        isConnecting = true
        nextAttempt = now().addingTimeInterval(Self.retryInterval)
        note("Connecting to \(candidate.name) as \(profile.model)…")

        let transport = RFCOMMTransport(address: address)
        let session = Session(transport: transport, profile: profile,
                              advertisedName: candidate.advertisedName,
                              log: { [weak self] line in
                                  Task { @MainActor in self?.note(line) }
                              })
        session.onChange = { [weak self] in
            Task { @MainActor in self?.sessionChanged() }
        }
        self.transport = transport
        self.session = session
        self.device = candidate
        session.start()

        // The display name is looked up in the background because it spawns a process, and
        // spawning one on the main thread for a cosmetic label is not worth the stutter.
        let addressCopy = address
        Task.detached {
            let name = DeviceCatalog.displayName(address: addressCopy)
            await MainActor.run { [weak self] in
                guard let self, self.device?.address == addressCopy, let name, !name.isEmpty else { return }
                self.device?.displayName = name
                self.objectWillChange.send()
            }
        }
    }

    func disconnect() {
        isConnecting = false
        session?.stop()
        session = nil
        transport = nil
        device = nil
        nextAttempt = now().addingTimeInterval(Self.retryInterval)
        objectWillChange.send()
    }

    private func sessionChanged() {
        if session?.phase == .closed {
            isConnecting = false
            // Keep the session object around for one tick so its closing reason can be shown, but
            // do not keep a dead link: the next tick re-connects.
            if let reason = session?.lastError { problem = reason }
        }
        if session?.phase == .ready { problem = nil }
        updateStatus()
        revision &+= 1
    }

    private func updateStatus() {
        guard let session else {
            if isPresent { status = "Waiting to connect…" }
            return
        }
        switch session.phase {
        case .closed:
            status = problem ?? "Disconnected."
        case .opening:
            status = "Connecting…"
        case .ready:
            status = session.hasReadAnything ? "Connected." : "Connected, reading…"
        }
    }

    // MARK: - Writes

    func set(mode: NoiseMode) { session?.set(mode: mode); sessionChanged() }
    func set(ancLevel: ANCLevel) { session?.set(ancLevel: ancLevel); sessionChanged() }
    func set(eqPreset: EQPreset) { session?.set(eqPreset: eqPreset); sessionChanged() }
    func set(bassWave level: Int) { session?.set(bassWave: level); sessionChanged() }
    func setGesture(_ gesture: BudsProtocol.MediaGesture, _ action: BudsProtocol.GestureAction) {
        session?.setGesture(gesture, action: action)
        sessionChanged()
    }

    // MARK: - Activity log

    /// A bounded ring of what happened. Not a debug console: the app ships this so a person can
    /// see that a write was declined, or that the codec changed, without a terminal.
    private func note(_ line: String) {
        activity.append(timestamp() + "  " + line)
        if activity.count > 200 { activity.removeFirst(activity.count - 200) }
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: now())
    }
}
