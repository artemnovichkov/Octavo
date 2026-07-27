#!/usr/bin/env swift
// Draws Resources/Octavo.icon, the Liquid Glass counterpart to Octavo.icns. Run it by hand
// after changing the artwork:
//
//     swift Scripts/make-liquid-icon.swift
//
// A .icon bundle is icon.json (layer/fill manifest) + Assets/*.png (the layer images) —
// see https://github.com/dfabulich/unofficial-apple-icon-composer-json-schema for the
// reverse-engineered schema; Icon Composer.app (ships inside Xcode 26) opens/edits it too.
// Unlike make-icon.swift, the plate is not baked into a raster: it becomes the icon's `fill`
// gradient, and the system renders the rounded-square mask, glass material and specular sheen
// around it. Only the page glyph — same geometry as make-icon.swift's sheet/dogEar/fold-line
// drawing — is rasterized, on a transparent canvas, as the one foreground layer.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(filePath: FileManager.default.currentDirectoryPath)
let bundle = root.appending(path: "Resources/Octavo.icon")
let assets = bundle.appending(path: "Assets")

// MARK: - Palette (matches make-icon.swift)

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}

let inkTop = rgb(0x4C46D6)      // indigo — becomes the icon.json fill gradient, not rasterized
let inkBottom = rgb(0x7C3AED)   // violet
let inkTopDark = rgb(0x312D8B)      // dark-appearance fill: same hues, ~65% brightness so the
let inkBottomDark = rgb(0x51269A)   // gradient survives instead of Icon Composer's default black
let paper = rgb(0xF7F1E3)       // warm cream
let paperShade = rgb(0xC9BC9E)  // underside of the turned corner
let paperLit = rgb(0xFBF7EC)
let paperDim = rgb(0xDED2B8)
let creaseDark = CGColor(red: 0.32, green: 0.26, blue: 0.16, alpha: 0.28)

func iconColor(_ color: CGColor) -> String {
    let c = color.components ?? [0, 0, 0, 1]
    return "srgb:\(String(format: "%.5f,%.5f,%.5f,%.5f", c[0], c[1], c[2], c[3]))"
}

// MARK: - Drawing
//
// Authored in the same 1024×1024 space as make-icon.swift, minus the plate: just the page.

func drawGlyph(in context: CGContext) {
    let sheet = CGRect(x: 322, y: 282, width: 380, height: 460)
    let dogEar: CGFloat = 96

    let page = CGMutablePath()
    page.move(to: CGPoint(x: sheet.minX, y: sheet.maxY))
    page.addLine(to: CGPoint(x: sheet.maxX, y: sheet.maxY))
    page.addLine(to: CGPoint(x: sheet.maxX, y: sheet.minY + dogEar))
    page.addLine(to: CGPoint(x: sheet.maxX - dogEar, y: sheet.minY))
    page.addLine(to: CGPoint(x: sheet.minX, y: sheet.minY))
    page.closeSubpath()

    context.addPath(page)
    context.setFillColor(paper)
    context.fillPath()

    // Underside of the turned corner.
    let ear = CGMutablePath()
    ear.move(to: CGPoint(x: sheet.maxX, y: sheet.minY + dogEar))
    ear.addLine(to: CGPoint(x: sheet.maxX - dogEar, y: sheet.minY + dogEar))
    ear.addLine(to: CGPoint(x: sheet.maxX - dogEar, y: sheet.minY))
    ear.closeSubpath()
    context.addPath(ear)
    context.setFillColor(paperShade)
    context.fillPath()

    // Fold lines: 1 vertical + 3 horizontal = the eight leaves of an octavo.
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

    let leaves = 4
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

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func render() throws -> CGImage {
    guard let context = CGContext(
        data: nil,
        width: 1024,
        height: 1024,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw Failure("could not create a 1024×1024 context")
    }
    drawGlyph(in: context)
    guard let image = context.makeImage() else { throw Failure("could not make the image") }
    return image
}

do {
    try? FileManager.default.removeItem(at: bundle)
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

    let image = try render()
    guard let destination = CGImageDestinationCreateWithURL(
        assets.appending(path: "page.png") as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        throw Failure("could not open page.png for writing")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw Failure("could not write page.png") }

    let orientation: [String: Any] = [
        "start": ["x": 0, "y": 1],
        "stop": ["x": 1, "y": 0],
    ]

    let manifest: [String: Any] = [
        "fill-specializations": [
            [
                "value": [
                    "linear-gradient": [iconColor(inkTop), iconColor(inkBottom)],
                    "orientation": orientation,
                ]
            ],
            [
                "appearance": "dark",
                "value": [
                    "linear-gradient": [iconColor(inkTopDark), iconColor(inkBottomDark)],
                    "orientation": orientation,
                ],
            ],
        ],
        "groups": [
            [
                "name": "Page",
                "specular": false,
                "shadow": ["kind": "neutral", "opacity": 0.35],
                "translucency": ["enabled": false, "value": 0],
                "layers": [
                    [
                        "image-name": "page.png",
                        "name": "Page",
                    ]
                ],
            ]
        ],
        "supported-platforms": ["squares": "shared"],
    ]

    let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: bundle.appending(path: "icon.json"))

    print(bundle.path(percentEncoded: false))
} catch {
    FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
    exit(1)
}
