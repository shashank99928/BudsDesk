import AppKit
import SwiftUI
import BudsCore

/// Drawing the window without a window.
///
/// One code path with two jobs: the picture the site shows and the regression check that says the
/// layout still adds up. Both are the real `DeviceWindow` over a real `AppModel`, driven by the
/// recording in `CaptureCorpus` — a separate mock-up would be a second answer that could disagree
/// with the app it depicts, which is the thing this project spends its effort avoiding.
///
/// A drawn surface is also the honest way to publish a screenshot from a machine with no earbuds
/// on the desk: the state is a recording rather than a wish, and the window's own footer names the
/// recording, so the image carries its provenance instead of borrowing the app's credibility.
///
/// Regenerate deliberately, and look at the result, with:
///
///     BudsDesk --render          # writes each surface to the path it declares
///     BudsDesk --compare         # what the build runs
@MainActor
enum Render {

    // MARK: - What is drawn

    /// The window a person gets. The app's window is 440 wide and the view has a 400pt floor, so a
    /// drawing has to be 440 wide or it is a drawing of a window nobody has; the height is the
    /// window's own 620, which also proves the content fits without a scroll for the states drawn.
    static let size = CGSize(width: 440, height: 620)

    struct Surface {
        /// The file name, and the name a failure uses.
        let name: String
        /// Where it lives, relative to the repository root. The site's image and the image the
        /// build verifies are one file on purpose: there is no second copy to drift, and the
        /// picture a visitor sees is the picture that passed.
        let path: String
        /// What the picture is supposed to show, so a failure reads as a sentence.
        let shows: String
        let scene: AppModel.Scene
    }

    /// The two states worth a picture: the model that was measured, doing what the recording shows
    /// it doing, and the state a first launch with the earbuds away lands in.
    static func surfaces() throws -> [Surface] {
        let registry = try RegistryLocation.load()
        guard let recording = CaptureCorpus.recordings.first else {
            throw Failure.noRecording
        }
        guard let profile = registry.profile(
            advertisedName: recording.provenance.model,
            serviceUUIDs: [DeviceCatalog.controlServiceUUIDString]) else {
            throw Failure.noProfile(recording.provenance.model)
        }

        return [
            Surface(
                name: "connected",
                path: "docs/assets/connected.png",
                shows: "the measured model, in the state replaying \(recording.provenance.id) "
                     + "leaves it in",
                scene: .replay(AppModel.Replay(
                    recording: recording,
                    profile: profile,
                    // Nothing in the window draws an address, which is why a stand-in is
                    // acceptable here rather than an invented one: it says so, and if it is ever
                    // drawn it will read as what it is.
                    device: PairedBudDevice(address: "00-00-00-00-00-00 (replay)",
                                            advertisedName: recording.provenance.model),
                    now: clock(on: recording.provenance.date)))),

            Surface(
                name: "away",
                path: "Tests/Goldens/away.png",
                shows: "no earbuds found — the first launch, and the state the app shows before "
                     + "anything is paired",
                scene: .away),
        ]
    }

    /// The recording's own date, at a fixed time of day.
    ///
    /// The activity log is a clock, so a drawing has to be given one: the same recording has to
    /// draw the same picture twice, and a build on another machine has to draw the same picture as
    /// this one. The date comes from the recording so the log reads like the session it came from
    /// rather than like today.
    private static func clock(on date: String) -> () -> Date {
        var components = DateComponents()
        let parts = date.split(separator: "-").compactMap { Int($0) }
        if parts.count == 3 {
            components.year = parts[0]
            components.month = parts[1]
            components.day = parts[2]
        }
        components.hour = 10
        components.minute = 9
        components.second = 12
        let fixed = Calendar.current.date(from: components) ?? Date(timeIntervalSince1970: 0)
        return { fixed }
    }

    // MARK: - Drawing

    /// Points per pixel the drawing is taken at, so the published picture stays sharp on a Retina
    /// display: the window is 440×620 points and the file is twice that.
    static let scale = 2

    /// Draw the window into a PNG.
    ///
    /// Not `ImageRenderer`, which was the first thing tried and produced a blank rectangle: on
    /// this OS it cannot rasterise a `ScrollView`, and the window is one. A hosted view can, at a
    /// stated scale, with the appearance the app pins.
    @MainActor
    static func png(_ surface: Surface) throws -> Data {
        let model = AppModel(scene: surface.scene)
        let view = NSHostingView(rootView: DeviceWindow(model: model)
            .environment(\.isRenderingSnapshot, true))
        view.frame = CGRect(origin: .zero, size: size)
        // The app asks for dark and stays there (see `BudsDeskApp`), so a drawing that took the
        // machine's appearance would be a picture of a window that never exists.
        view.appearance = NSAppearance(named: .darkAqua)
        settle(view, model: model)

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width) * scale,
            pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw Failure.nothingRendered(surface.name)
        }
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw Failure.nothingRendered(surface.name)
        }
        return data
    }

    /// Let the view lay out, and let the session's log lines land.
    ///
    /// Two things arrive after the call that starts them, and both are in the picture: SwiftUI's
    /// first layout, and the replay's log lines, which reach the model through the main actor. So
    /// the run loop turns until the model has stopped growing for several turns in a row — not a
    /// fixed sleep, which would be a race against however fast the machine happens to be.
    private static func settle(_ view: NSView, model: AppModel) {
        view.layoutSubtreeIfNeeded()
        var lastCount = -1
        var stable = 0
        for _ in 0..<200 {
            if model.activity.count == lastCount {
                stable += 1
                if stable >= 3 { break }
            } else {
                stable = 0
                lastCount = model.activity.count
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            view.layoutSubtreeIfNeeded()
        }
    }

    /// `--render`: draw every surface to the path it declares.
    @MainActor
    static func write(to root: URL) throws -> [String] {
        var written: [String] = []
        for surface in try surfaces() {
            let data = try png(surface)
            let destination = root.appendingPathComponent(surface.path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: destination)
            written.append("\(surface.path) — \(surface.shows)")
        }
        return written
    }

    // MARK: - Comparing

    struct Comparison {
        let name: String
        let path: String
        let differing: Int
        let total: Int
        /// A missing golden is not a pass and not a failure: it is a surface nobody has drawn yet,
        /// and the build says so rather than pretending to have checked it.
        let missing: Bool
        /// A surface that changed size is a different layout, not a slightly different render, so
        /// size is compared exactly and reported as itself.
        let resized: (drawn: CGSize, golden: CGSize)?

        var ratio: Double { total == 0 ? 0 : Double(differing) / Double(total) }
        var passed: Bool { !missing && resized == nil && ratio < 0.005 }
    }

    /// Per-pixel comparison with a small tolerance rather than exact bytes: two macOS builds can
    /// encode identical pixels differently, and a check that fails on an OS update teaches people
    /// to ignore it. The tolerance is two levels per channel and half a percent of the picture.
    @MainActor
    static func compare(in root: URL, tolerance: Int = 2) throws -> [Comparison] {
        try surfaces().map { surface in
            let golden = root.appendingPathComponent(surface.path)
            guard let goldenData = try? Data(contentsOf: golden) else {
                return Comparison(name: surface.name, path: surface.path, differing: 0, total: 0,
                                  missing: true, resized: nil)
            }
            let drawn = try png(surface)
            let (differing, total, sizes) = try difference(drawn, goldenData, tolerance: tolerance)
            return Comparison(name: surface.name, path: surface.path, differing: differing,
                              total: total, missing: false,
                              resized: sizes.0 == sizes.1 ? nil : (sizes.0, sizes.1))
        }
    }

    /// The number of pixels that differ by more than `tolerance` levels in any channel, and the
    /// total compared, plus the two sizes so a mismatch can be reported as itself.
    static func difference(_ lhs: Data, _ rhs: Data,
                           tolerance: Int) throws -> (Int, Int, (CGSize, CGSize)) {
        guard let left = NSBitmapImageRep(data: lhs), let right = NSBitmapImageRep(data: rhs) else {
            throw Failure.goldenDidNotDecode
        }
        let leftSize = CGSize(width: left.pixelsWide, height: left.pixelsHigh)
        let rightSize = CGSize(width: right.pixelsWide, height: right.pixelsHigh)
        guard leftSize == rightSize else { return (0, 0, (leftSize, rightSize)) }
        guard let a = rgba(left), let b = rgba(right) else { throw Failure.goldenDidNotDecode }

        var differing = 0
        var index = 0
        while index < a.count {
            if abs(Int(a[index]) - Int(b[index])) > tolerance
                || abs(Int(a[index + 1]) - Int(b[index + 1])) > tolerance
                || abs(Int(a[index + 2]) - Int(b[index + 2])) > tolerance
                || abs(Int(a[index + 3]) - Int(b[index + 3])) > tolerance {
                differing += 1
            }
            index += 4
        }
        return (differing, Int(leftSize.width * leftSize.height), (leftSize, rightSize))
    }

    /// One canonical RGBA8 buffer per image, so the comparison never depends on how the decoder
    /// happened to lay the bytes out.
    private static func rgba(_ rep: NSBitmapImageRep) -> [UInt8]? {
        guard let image = rep.cgImage else { return nil }
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return ok ? bytes : nil
    }

    enum Failure: Error, CustomStringConvertible {
        case noRecording
        case noProfile(String)
        case nothingRendered(String)
        case goldenDidNotDecode

        var description: String {
            switch self {
            case .noRecording:
                return "the bundled corpus has no recording to draw"
            case .noProfile(let model):
                return "no profile matches \(model), so there is nothing to draw it as"
            case .nothingRendered(let name):
                return "\(name): ImageRenderer produced nothing"
            case .goldenDidNotDecode:
                return "a PNG in the comparison did not decode"
            }
        }
    }
}

/// Set while the app draws itself off-screen.
///
/// `ImageRenderer` cannot rasterise AppKit-backed controls: a `Menu` comes out as a coloured
/// placeholder bar. That would put a broken-looking control into a published screenshot and then
/// pin the breakage in a golden, so the one view that uses a menu draws a static label instead —
/// the same label the menu shows — while this is set. The scene has no `glassEffect` and no other
/// AppKit-backed control, which is what lets a drawing be deterministic at all.
extension EnvironmentValues {
    var isRenderingSnapshot: Bool {
        get { self[RenderingSnapshotKey.self] }
        set { self[RenderingSnapshotKey.self] = newValue }
    }
}

private struct RenderingSnapshotKey: EnvironmentKey {
    static let defaultValue = false
}
