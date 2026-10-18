import Foundation
import IOBluetooth

/// A paired Bluetooth device that advertises the vendor's control service.
public struct PairedBudDevice: Sendable, Identifiable {
    public let address: String
    /// The name the hardware advertises over the air. This is *not* always what Bluetooth
    /// settings shows: rename a device on the phone and the two drift apart.
    public let advertisedName: String
    /// The name Bluetooth settings shows, when the daemon could be asked. Only
    /// `system_profiler` reports it — it is in no readable preference file — so it is looked up
    /// on demand rather than on every poll.
    public var displayName: String?

    public var id: String { address }

    /// What to call it in a UI: the display name, then the advertised name, then the address.
    public var name: String {
        if let displayName, !displayName.isEmpty { return displayName }
        if !advertisedName.isEmpty { return advertisedName }
        return address
    }
}

/// Finding the earbuds.
///
/// Matching is on the **service the device advertises**, never on a name and never on a
/// hardcoded address. That is what makes this app device-generic: any model speaking this
/// protocol is a candidate, and no one's Bluetooth address ends up in the source.
public enum DeviceCatalog {

    /// The SDP UUID of the vendor's control service.
    public static let controlServiceUUIDBytes: [UInt8] = [
        0x00, 0x00, 0x07, 0x9a, 0xd1, 0x02, 0x11, 0xe1,
        0x9b, 0x23, 0x00, 0x02, 0x5b, 0x00, 0xa5, 0xa5,
    ]

    public static var controlServiceUUIDString: String { "0000799a-d102-11e1-9b23-00025b00a5a5" }

    /// Every paired device that advertises the control service.
    ///
    /// This relies on the SDP records cached at pairing time — nothing is paged — so it is
    /// cheap enough to call on a poll. A device paired *while* this app runs appears here too,
    /// which is why callers re-ask rather than caching the answer once.
    public static func candidates() -> [PairedBudDevice] {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            // A process without Bluetooth TCC permission sees exactly this: an empty list, and
            // no error at all. It is a permission problem, not a discovery bug.
            return []
        }
        let uuid = IOBluetoothSDPUUID(bytes: controlServiceUUIDBytes, length: 16)
        return paired.compactMap { device in
            guard device.getServiceRecord(for: uuid) != nil,
                  let address = device.addressString else { return nil }
            return PairedBudDevice(address: address,
                                   advertisedName: device.name ?? "",
                                   displayName: nil)
        }
    }

    /// The device at an address, if it is paired and advertises the service.
    ///
    /// Used by `BUDSDESK_ADDRESS`, which names one device when several are paired — and by a
    /// user who has more than one pair of these earbuds.
    public static func candidate(address: String) -> PairedBudDevice? {
        let wanted = normalise(address)
        return candidates().first { normalise($0.address) == wanted }
    }

    private static func normalise(_ address: String) -> String {
        address.replacingOccurrences(of: "-", with: ":").uppercased()
    }

    /// The name Bluetooth settings shows for an address.
    ///
    /// Each device is a single-pair dictionary keyed by its display name, so the key is the value
    /// wanted and the address inside identifies which entry is ours. Both the connected and the
    /// not-connected lists are searched, so the name is right even when the buds are away.
    public static func displayName(address: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        // Drain before waiting: a full pipe buffer would deadlock the child.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]]
        else { return nil }

        let wanted = normalise(address)
        for section in sections {
            for listKey in ["device_connected", "device_not_connected"] {
                guard let list = section[listKey] as? [[String: Any]] else { continue }
                for entry in list {
                    for (displayName, raw) in entry {
                        guard let info = raw as? [String: Any],
                              let addr = info["device_address"] as? String,
                              normalise(addr) == wanted
                        else { continue }
                        return displayName
                    }
                }
            }
        }
        return nil
    }
}
