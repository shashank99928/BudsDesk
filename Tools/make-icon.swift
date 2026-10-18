#!/usr/bin/env swift
//
// Draws the BudsDesk app icon — an equalizer mark on a dark squircle — and packs it
// into Resources/AppIcon.iconset/ and Resources/AppIcon.icns.
//
// Generated rather than checked in, because a checked-in PNG cannot be re-tuned when the icon
// grid or the palette moves, cannot be audited for what it actually contains, and would put a
// licence question on artwork that here is nothing but CoreGraphics calls — which is the rule
// in this repository: every visual is drawn by code, never lifted from a vendor's asset.
//
// Run:  swift Tools/make-icon.swift
//
import AppKit
import SwiftUI

// The palette is BudsDesk's own: a near-black surface and exactly one bright accent. The accent
// is a soft green rather than any vendor's colour — this app is not OPPO's, OnePlus's or
// realme's, and the icon must not suggest otherwise. There is no logo here to infringe: an
// earbud drawn from two primitives is a generic shape, not a trademark.
private let surfaceTop = Color(red: 0.078, green: 0.086, blue: 0.102)   // #14161A
private let surfaceBottom = Color(red: 0.043, green: 0.047, blue: 0.055) // #0B0C0E
private let accent = Color(red: 0.42, green: 0.82, blue: 0.55)           // soft green
// The far end of the mark's own gradient. Deliberately close to `accent`: an earlier version
// ran all the way down to a dark green, and at 16 points the bars appeared to fade out rather
// than end, which reads as a rendering fault. A gradient should suggest depth, not remove
// contrast from the small end.
private let accentDeep = Color(red: 0.30, green: 0.68, blue: 0.44)

/// Apple's macOS app-icon grid: the squircle occupies 824 of 1024 points — roughly 10% padding,
/// which is why a native icon never bleeds to the edge of its canvas — with a corner radius of
/// 186. A continuous-corner squircle is used rather than a circular-arc rounded rect because the
/// two are visibly different side by side in the Dock.
private func iconMetrics(_ size: CGFloat) -> (inset: CGFloat, body: CGFloat, radius: CGFloat) {
    let inset = size * (100.0 / 1024.0)
    return (inset, size - inset * 2, size * (186.0 / 1024.0))
}

/// The mark: three bars, the middle one tallest.
///
/// **Why not an earbud.** Five revisions of this file drew a literal earbud and every one of them
/// read as a different object:
///
/// | drawn | read as |
/// |---|---|
/// | a tall capsule on a stem | a microphone |
/// | a circle on a stem | a person |
/// | two circles leaning apart | a green smudge at 16 points |
/// | a squat body with a nozzle, tilted | a hand mirror |
/// | the same pair, nozzles outward | two crowns |
///
/// That is not a drawing problem, it is the shape: an earbud *is* a blob on a stick, and so is a
/// lollipop, a microphone, a mirror and a pin, with nothing left at 16 points to tell them apart.
/// The honest conclusion was to stop trying to win a fight the medium cannot win, and draw the
/// thing the app actually does instead.
///
/// **Why this is not a cop-out.** BudsDesk's reason to exist is changing settings on earbuds whose
/// own app is phone-only: the equalizer and the noise-control mode, which is the first thing
/// anyone opens it for. Bars are what "audio settings" looks like, they are unambiguous at 16
/// points — three strokes cannot be confused with anything else at that size — and they are true
/// of this app rather than aspirational about it. This icon makes no claim the software does not
/// keep.
///
/// Bars are drawn with `addRoundedRect` so the caps keep their radius at every scale, rather than
/// as a stroked path whose cap style would dissolve at the small end.
private func equalizerBars(in rect: CGRect) -> Path {
    let w = rect.width, h = rect.height
    // Uneven on purpose. Three equal bars is a menu; three unequal ones is a level reading.
    let heights: [CGFloat] = [0.52, 0.88, 0.70]
    let count = CGFloat(heights.count)
    // A fifth of the mark's width each, with the gaps slightly narrower than the bars. At 16
    // points that is about two pixels of colour and two of gap, which is the smallest this can be
    // and still read as three separate strokes rather than a hatched block.
    let barW = w * 0.22
    let step = (w - barW) / (count - 1)

    var path = Path()
    for (index, fraction) in heights.enumerated() {
        let barH = h * fraction
        path.addRoundedRect(
            in: CGRect(x: CGFloat(index) * step, y: (h - barH) / 2,
                       width: barW, height: barH),
            cornerSize: CGSize(width: barW / 2, height: barW / 2))
    }
    return path
}

private struct IconArt: View {
    let size: CGFloat

    var body: some View {
        let m = iconMetrics(size)
        let shape = RoundedRectangle(cornerRadius: m.radius, style: .continuous)

        // The mark's own geometry, in points on this canvas.
        let markW = m.body * 0.680
        let markH = m.body * 0.600
        // Coordinates here are in the ZStack's own space, which is `m.body` square — the 10%
        // inset is the outer `.frame`. Writing `m.inset + …` here is the bug that made every
        // early render of this icon sit exactly one inset down and to the right: the mark was
        // being placed with canvas coordinates inside a content-box space. `Tools/` has no test
        // that could catch it, so it is written down instead.
        let centre = m.body / 2

        ZStack {
            // The surface, and the one accent arriving as a glow from the top.
            shape.fill(LinearGradient(colors: [surfaceTop, surfaceBottom],
                                      startPoint: .top, endPoint: .bottom))
            shape.fill(RadialGradient(colors: [accent.opacity(0.16), .clear],
                                      center: UnitPoint(x: 0.5, y: 0.30),
                                      startRadius: 0, endRadius: m.body * 0.58))

            // The bars.
            Bars()
                .frame(width: markW, height: markH)
                .position(x: centre, y: m.body * 0.495)

            // A hairline, for the edge that a real icon has and a flat fill does not.
            shape.strokeBorder(Color.white.opacity(0.10), lineWidth: max(1, size * 0.004))
        }
        .frame(width: m.body, height: m.body)
        .frame(width: size, height: size)
    }
}

/// The bars, filled and given their one bit of depth.
private struct Bars: View {
    var body: some View {
        GeometryReader { geo in
            equalizerBars(in: CGRect(origin: .zero, size: geo.size))
                .fill(LinearGradient(colors: [accent, accentDeep],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                // A hair of separation from the dark surface, so the bars never bleed into the
                // glow behind them when the icon is small.
                .shadow(color: Color.black.opacity(0.45), radius: 0.5, y: 0.4)
        }
    }
}

@MainActor
private func render(_ size: Int) -> NSBitmapImageRep? {
    let renderer = ImageRenderer(content: IconArt(size: CGFloat(size)))
    renderer.scale = 1
    guard let cgImage = renderer.cgImage else { return nil }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    rep.size = NSSize(width: size, height: size)
    return rep
}

/// (filename, pixel size) — the ten entries `iconutil` wants. Every one of them is emitted;
/// a missing entry makes `iconutil` fall back to a scaled neighbour in the Dock.
private let variants: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

await MainActor.run {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: fm.currentDirectoryPath)
    let iconset = root.appendingPathComponent("Resources/AppIcon.iconset")
    let icns = root.appendingPathComponent("Resources/AppIcon.icns")

    // Remove-then-create keeps the run idempotent: a second run rewrites the same ten files and
    // leaves no strays from a size that was dropped.
    try? fm.removeItem(at: iconset)
    try? fm.removeItem(at: icns)
    try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)

    for (name, size) in variants {
        guard let rep = render(size),
              let data = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("failed to render \(name)\n".utf8))
            exit(1)
        }
        try! data.write(to: iconset.appendingPathComponent(name))
    }
}

// iconutil has to run on the normal path, after the main-actor block above has written the
// iconset. It is the system's own packer, so the .icns carries exactly the ten sizes emitted
// here and no image is ever rescaled twice.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = [
    "-c", "icns",
    root.appendingPathComponent("Resources/AppIcon.iconset").path,
    "-o", root.appendingPathComponent("Resources/AppIcon.icns").path,
]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}

print("wrote Resources/AppIcon.icns")
