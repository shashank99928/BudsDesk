import Foundation

/// Where each bud is, as the buds report it. nil until they have said.
///
/// This is what stops a bud charging in the case from being drawn as one in use. It also covers a
/// gap in the battery report: a bud in the case drops out of it entirely rather than reporting as
/// unknown, and an absent slot deliberately keeps its last value — so without placement the
/// surface would show a frozen percentage for a bud that was put away.
public struct Placement: Equatable, Sendable {
    public var left: BudsProtocol.BudPlacement?
    public var right: BudsProtocol.BudPlacement?
    /// Where the case reported itself. Not a bud, but the wear report names the slot, and it is
    /// the only evidence the app has that a case exists at all — the battery report drops the
    /// case out entirely while it is asleep, which is most of the time.
    public var enclosure: BudsProtocol.BudPlacement?

    public init() {}

    public subscript(slot: BudsProtocol.BatterySlot) -> BudsProtocol.BudPlacement? {
        get {
            switch slot {
            case .left: return left
            case .right: return right
            case .enclosure: return enclosure
            }
        }
        set {
            switch slot {
            case .left: left = newValue
            case .right: right = newValue
            case .enclosure: enclosure = newValue
            }
        }
    }

    /// Whether a case is actually there.
    ///
    /// The wear report is the only evidence while the case is asleep — a sleeping case drops out
    /// of the battery report entirely, which is its usual state — but a slot reported as
    /// `.notPresent` means there is no case, not an unknown one, so it does not count.
    public var isCaseReported: Bool { enclosure.map { $0 != .notPresent } ?? false }
}

/// The charge levels, as raw bytes. nil is "not reported", and the difference between that and
/// "reported as unknown" lives in `BudsProtocol`'s decoder, not here.
public struct BatteryLevels: Equatable, Sendable {
    public var left: Int?
    public var right: Int?
    public var enclosure: Int?

    public init() {}

    public subscript(slot: BudsProtocol.BatterySlot) -> Int? {
        get {
            switch slot {
            case .left: return left
            case .right: return right
            case .enclosure: return enclosure
            }
        }
        set {
            switch slot {
            case .left: left = newValue
            case .right: right = newValue
            case .enclosure: enclosure = newValue
            }
        }
    }
}

extension BudsProtocol.BudPlacement {
    /// False for a bud stowed in the case or gone absent: neither is a bud *in use*, so its
    /// reading is dropped rather than feeding the headline as though the bud were still in an
    /// ear. `.notPresent` is decodable but was never observed on this hardware, so it is folded
    /// in with `.inCase` defensively rather than guessed into a fourth behaviour.
    ///
    /// Used by the session — which clears the reading — and by the UI, which dims the chip, so
    /// the two cannot disagree.
    public var isUsable: Bool { self == .inEar || self == .outOfCase }
}
