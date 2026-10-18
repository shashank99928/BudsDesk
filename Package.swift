// swift-tools-version: 6.2
import PackageDescription
import Foundation

// SwiftUI's @State and @Bindable are macros, and the Command Line Tools ship SwiftUI without
// its macro plugin — so `swift build` and SourceKit both fail on every property wrapper unless
// the plugin is supplied explicitly. Borrow the dylib from any installed Xcode; it loads into
// the CLT compiler even when that Xcode's own toolchain is too old to run on this OS. Declaring
// it here rather than only in build.sh keeps the editor and a bare `swift build` working too.
let swiftUIMacros: [SwiftSetting] = {
    let candidates = (try? FileManager.default.contentsOfDirectory(atPath: "/Applications"))?
        .filter { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }
        .map {
            "/Applications/\($0)/Contents/Developer/Platforms/MacOSX.platform"
                + "/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib"
        } ?? []

    guard let plugin = candidates.first(where: { FileManager.default.fileExists(atPath: $0) })
    else { return [] }          // no Xcode: fall through and let the compiler complain
    return [.unsafeFlags(["-load-plugin-library", plugin])]
}()

// Everything runs on the main thread apart from two explicit dispatches, and IOBluetooth
// predates Sendable. Strict concurrency checking buys nothing but ceremony at this size.
let shared: [SwiftSetting] = [.swiftLanguageMode(.v5)] + swiftUIMacros

let package = Package(
    name: "BudsDesk",
    platforms: [.macOS(.v26)],
    targets: [
        // The protocol core. Foundation-only and transport-agnostic on purpose: it holds no
        // radio, so the same bytes-in/bytes-out layer can be driven by an IOBluetooth channel
        // here, a WinRT stream on Windows and a BlueZ socket on Linux without a decoder
        // changing. Nothing in this target may import IOBluetooth, CoreBluetooth or SwiftUI.
        .target(name: "BudsCore", path: "Sources/BudsCore", swiftSettings: shared),

        // Everything that is genuinely macOS's own: the IOBluetooth transport, device discovery,
        // the registry's on-disk location, the SwiftUI surfaces, and the app's own entry point.
        // It depends on BudsCore and BudsCore does not know it exists.
        .target(name: "BudsDeskMac", dependencies: ["BudsCore"],
                path: "Sources/BudsDeskMac", swiftSettings: shared),

        .executableTarget(name: "BudsDesk", dependencies: ["BudsCore", "BudsDeskMac"],
                          path: "Sources/BudsDesk", swiftSettings: shared),

        .testTarget(name: "BudsCoreTests", dependencies: ["BudsCore"],
                    path: "Tests/BudsCoreTests", swiftSettings: shared),
    ]
)
