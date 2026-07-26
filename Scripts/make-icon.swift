#!/usr/bin/env swift
// Draws Octavo.icns. Run it by hand after changing the artwork:
//
//     swift Scripts/make-icon.swift
//
// The generated Resources/Octavo.icns is committed, so make-app.sh stays a pure copy and
// building the app never depends on this script.
//
// The mark is the name made literal: an octavo is a sheet folded three times into eight
// leaves, so the page carries one vertical and three horizontal fold lines, plus a turned
// corner. Fold lines are dropped at small sizes, where they would only turn to mud.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(filePath: FileManager.default.currentDirectoryPath)
let iconset = root.appending(path: "Resources/Octavo.iconset")
let icns = root.appending(path: "Resources/Octavo.icns")

// MARK: - Palette

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}

let inkTop = rgb(0x4C46D6)      // indigo
let inkBottom = rgb(0x7C3AED)   // violet
let paper = rgb(0xF7F1E3)       // warm cream
let paperShade = rgb(0xC9BC9E)  // the underside of the turned corner
// Each leaf is shaded from dim at its lower crease to lit at its upper one, so the sheet
// catches light the way an accordion fold does. Ruling the panels with plain lines instead
// just produced a spreadsheet.
let paperLit = rgb(0xFBF7EC)
let paperDim = rgb(0xDED2B8)
let creaseDark = CGColor(red: 0.32, green: 0.26, blue: 0.16, alpha: 0.28)

// MARK: - Drawing
//
// Everything is authored in a 1024×1024 space and scaled to the requested size.

func drawIcon(in context: CGContext, size: CGFloat) {
    let scale = size / 1024
    context.scaleBy(x: scale, y: scale)
    context.setShouldAntialias(true)

    // Rounded-rect app shape, inset so the Dock's shadow has room.
    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    let radius: CGFloat = 185
    let platePath = CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil)

    context.saveGState()
    context.addPath(platePath)
    context.clip()
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [inkTop, inkBottom] as CFArray,
        locations: [0, 1]
    ) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: plate.minX, y: plate.maxY),
            end: CGPoint(x: plate.maxX, y: plate.minY),
            options: []
        )
    }
    context.restoreGState()

    // The sheet, with the bottom-right corner turned back.
    let sheet = CGRect(x: 322, y: 282, width: 380, height: 460)
    let dogEar: CGFloat = 96

    let page = CGMutablePath()
    page.move(to: CGPoint(x: sheet.minX, y: sheet.maxY))
    page.addLine(to: CGPoint(x: sheet.maxX, y: sheet.maxY))
    page.addLine(to: CGPoint(x: sheet.maxX, y: sheet.minY + dogEar))
    page.addLine(to: CGPoint(x: sheet.maxX - dogEar, y: sheet.minY))
    page.addLine(to: CGPoint(x: sheet.minX, y: sheet.minY))
    page.closeSubpath()

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 28,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.28))
    context.addPath(page)
    context.setFillColor(paper)
    context.fillPath()
    context.restoreGState()

    // Underside of the turned corner.
    let ear = CGMutablePath()
    ear.move(to: CGPoint(x: sheet.maxX, y: sheet.minY + dogEar))
    ear.addLine(to: CGPoint(x: sheet.maxX - dogEar, y: sheet.minY + dogEar))
    ear.addLine(to: CGPoint(x: sheet.maxX - dogEar, y: sheet.minY))
    ear.closeSubpath()
    context.addPath(ear)
    context.setFillColor(paperShade)
    context.fillPath()

    // Fold lines: 1 vertical + 3 horizontal = the eight leaves of an octavo. At 32pt and
    // below they stop resolving, so the page reads as a plain sheet instead of a smudge.
    // Below 64px the leaves stop resolving and the sheet is better left plain.
    guard size >= 64 else { return }
    let leaves = size >= 128 ? 4 : 2

    context.saveGState()
    context.addPath(page)
    context.clip()

    guard let fold = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [paperDim, paperLit] as CFArray,
        locations: [0, 1]
    ) else {
        context.restoreGState()
        return
    }

    let leafHeight = sheet.height / CGFloat(leaves)
    for index in 0..<leaves {
        let bottom = sheet.minY + leafHeight * CGFloat(index)
        context.saveGState()
        context.clip(to: CGRect(x: sheet.minX, y: bottom, width: sheet.width, height: leafHeight))
        context.drawLinearGradient(
            fold,
            start: CGPoint(x: 0, y: bottom),
            end: CGPoint(x: 0, y: bottom + leafHeight),
            options: []
        )
        context.restoreGState()
    }

    // The one fold running the other way — this is what makes it eight leaves and not four.
    context.setStrokeColor(creaseDark)
    context.setLineWidth(5)
    context.move(to: CGPoint(x: sheet.midX, y: sheet.minY))
    context.addLine(to: CGPoint(x: sheet.midX, y: sheet.maxY))
    context.strokePath()
    context.restoreGState()

    // Redraw the turned corner so the leaf shading does not paint over it.
    context.addPath(ear)
    context.setFillColor(paperShade)
    context.fillPath()
}

// MARK: - Output

func render(size: Int) throws -> CGImage {
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw Failure("could not create a \(size)×\(size) context")
    }
    drawIcon(in: context, size: CGFloat(size))
    guard let image = context.makeImage() else { throw Failure("could not make the image") }
    return image
}

func write(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        throw Failure("could not open \(url.lastPathComponent) for writing")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw Failure("could not write \(url.lastPathComponent)") }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// The ten entries iconutil expects.
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

do {
    try? FileManager.default.removeItem(at: iconset)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

    for variant in variants {
        let image = try render(size: variant.pixels)
        try write(image, to: iconset.appending(path: "\(variant.name).png"))
    }

    let iconutil = Process()
    iconutil.executableURL = URL(filePath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path(percentEncoded: false), "-o", icns.path(percentEncoded: false)]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else { throw Failure("iconutil returned \(iconutil.terminationStatus)") }

    // The .iconset is an intermediate; only the .icns is committed.
    try FileManager.default.removeItem(at: iconset)
    print(icns.path(percentEncoded: false))
} catch {
    FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
    exit(1)
}
