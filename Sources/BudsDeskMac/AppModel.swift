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

    // MARK: Private

    private var registry: CapabilityRegistry?
    private var transport: RFCOMMTransport?
    private var ticker: Timer?
    private var nextAttempt = Date.distantPast
    private var isConnecting = false

    private static let tick: TimeInterval = 2
    private static let retryInterval: TimeInterval = 6

    init() {
        loadRegistry()
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
    }

    deinit {
        ticker?.invalidate()
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
            status = "The capability registry could not be read."
        }
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

        if session == nil, !isConnecting, Date() >= nextAttempt {
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
            problem = "No profile matched and the registry has no fallback."
            return
        }
        self.profile = profile

        isConnecting = true
        nextAttempt = Date().addingTimeInterval(Self.retryInterval)
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
        nextAttempt = Date().addingTimeInterval(Self.retryInterval)
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
        activity.append(Self.timestamp() + "  " + line)
        if activity.count > 200 { activity.removeFirst(activity.count - 200) }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }
}
