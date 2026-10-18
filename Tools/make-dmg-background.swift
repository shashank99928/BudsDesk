#!/usr/bin/env swift
//
// Draws the disk-image background for make-dmg.sh: a dark field with the app's name, an arrow
// pointing from the app to Applications, and nothing else.
//
// Generated rather than checked in, because the artwork has to line up with icon positions that
// live in make-dmg.sh — if those coordinates move, this file must move with them, and a checked-in
// PNG would silently drift out of alignment or need hand-editing in an image editor. It also
// carries no third-party asset and therefore no licence question.
//
// Two files are produced — `dmg-background.png` at 1x and `dmg-background@2x.png` at 2x. Finder
// picks the @2x on a Retina display by itself, the same way it does for app artwork, so the image
// stays sharp without the toolkit guessing at DPI.
//
// The window it is drawn for is 660x420 (Finder bounds {200, 120, 860, 540}). make-dmg.sh puts the
// app icon at {165, 205} and the Applications shortcut at {495, 205}, counted from the top; the
// arrow below is centred between them at x=330 for exactly that reason.
//
// Run:  swift Tools/make-dmg-background.swift
//
import AppKit
import SwiftUI

// The same palette as the icon, so the image and the volume's own icon do not disagree.
private let surfaceTop = Color(red: 0.078, green: 0.086, blue: 0.102)   // #14161A
private let surfaceBottom = Color(red: 0.043, green: 0.047, blue: 0.055) // #0B0C0E
private let accent = Color(red: 0.42, green: 0.82, blue: 0.55)           // soft green

/// The arrow, drawn rather than taken from SF Symbols: an arrow is the one shape whose length and
/// head angle have to be tuned against the gap between the two icons, and a symbol cannot be
/// stretched to the right length without distorting its head.
private struct Arrow: Shape {
    func path(in rect: CGRect) -> Path {
        let midY = rect.midY
        let shaftH = rect.height * 0.26
        let headLen = rect.height * 0.92
        let headHalf = rect.height * 0.5
        var path = Path()

        // Shaft: a capsule, so both ends are round and the tail does not look chopped off.
        path.addRoundedRect(
            in: CGRect(x: rect.minX, y: midY - shaftH / 2,
                       width: rect.width - headLen * 0.75, height: shaftH),
            cornerSize: CGSize(width: shaftH / 2, height: shaftH / 2))
        // Head: a wide, shallow triangle. Shallow because the two icons it points between are
        // 266 points apart, and a steep arrow reads as a warning sign rather than a movement.
        let baseX = rect.maxX - headLen
        path.move(to: CGPoint(x: rect.maxX, y: midY))
        path.addLine(to: CGPoint(x: baseX, y: midY - headHalf))
        path.addLine(to: CGPoint(x: baseX, y: midY + headHalf))
        path.closeSubpath()
        return path
    }
}

private struct DmgBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [surfaceTop, surfaceBottom],
                           startPoint: .top, endPoint: .bottom)

            // The single accent, arriving as light from above rather than as a shape.
            RadialGradient(colors: [accent.opacity(0.16), .clear],
                           center: UnitPoint(x: 0.5, y: -0.05),
                           startRadius: 0, endRadius: 430)

            VStack(spacing: 5) {
                Text("BudsDesk")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                // The product line, as plain text. Vendor names are factual device names here —
                // there is no vendor mark and no vendor colour anywhere in this image.
                Text("OPPO · OnePlus · realme wireless earbuds, driven from your Mac")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .position(x: 330, y: 76)

            // Centred on the exact line the two icons share, so the eye follows app → arrow →
            // Applications without the arrow drifting above or below them.
            Arrow()
                .fill(accent.opacity(0.92))
                .shadow(color: accent.opacity(0.55), radius: 9)
                .frame(width: 150, height: 28)
                .position(x: 330, y: 205)

            // Deliberately well below the icons: Finder draws each icon's name underneath it, and
            // an instruction that lands on top of a filename is worse than no instruction.
            Text("Drag the app into Applications to install")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.50))
                .position(x: 330, y: 326)

            Text("Requires macOS 26 or later  ·  Open source, MIT licensed  ·  Never talks to a network")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.34))
                .position(x: 330, y: 388)
        }
        .frame(width: 660, height: 420)
    }
}

@MainActor
private func png(scale: CGFloat) -> Data? {
    let renderer = ImageRenderer(content: DmgBackground())
    renderer.scale = scale
    guard let cgImage = renderer.cgImage else { return nil }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    rep.size = NSSize(width: 660 * scale, height: 420 * scale)
    return rep.representation(using: .png, properties: [:])
}

await MainActor.run {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: fm.currentDirectoryPath)
    let resources = root.appendingPathComponent("Resources")
    try? fm.createDirectory(at: resources, withIntermediateDirectories: true)

    // Writing straight over the two paths is what makes this idempotent: a second run replaces
    // both files and cannot accumulate duplicates.
    for (name, scale) in [("dmg-background.png", CGFloat(1)),
                          ("dmg-background@2x.png", CGFloat(2))] {
        guard let data = png(scale: scale) else {
            FileHandle.standardError.write(Data("failed to render \(name)\n".utf8))
            exit(1)
        }
        let url = resources.appendingPathComponent(name)
        do {
            try data.write(to: url)
        } catch {
            FileHandle.standardError.write(Data("failed to write \(name): \(error)\n".utf8))
            exit(1)
        }
    }
}

print("wrote Resources/dmg-background.png and dmg-background@2x.png")
