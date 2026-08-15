#!/usr/bin/env swift
// Renders the app icon — the "cursor fuel" mark: a phosphor-mint prompt
// chevron beside a block cursor whose charge is the window budget left — into
// an .iconset directory of PNGs. The mark lives in code so the repo stays
// asset-free and the icon diffs like everything else.
//
// Usage: swift scripts/icon.swift [output.iconset]

import CoreGraphics
import Foundation
import ImageIO

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func rgba(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        colorSpace: srgb,
        components: [
            CGFloat((hex >> 16) & 0xFF) / 255,
            CGFloat((hex >> 8) & 0xFF) / 255,
            CGFloat(hex & 0xFF) / 255,
            alpha,
        ])!
}

let tileTop = rgba(0x27262C)
let tileBottom = rgba(0x141318)
let tileEdge = rgba(0xFFFFFF, 0.07)
let mint = rgba(0x45D48A)
let cursorTrack = rgba(0x3A3A44)
let fuelBottom = rgba(0xFFD60A)
let fuelTop = rgba(0xFF9F0A)
let baselineInk = rgba(0x33333C)
let shadowInk = rgba(0x000000, 0.30)

// Geometry lives in the concept's 512-pt design space; the 440-pt tile maps
// onto Apple's 824-pt icon grid of a 1024 canvas, which lands the tile's
// 99-pt corner on the canonical 185.4-pt macOS radius.
let canvas: CGFloat = 1024
let gridScale: CGFloat = 824.0 / 440.0
let gridOffset: CGFloat = 100 - 36 * gridScale

struct Mark {
    /// ≤32 px: heavier chevron, no baseline — detail that small is just blur.
    let simplified: Bool

    func draw(in ctx: CGContext, pixels: Int) {
        let px = CGFloat(pixels)
        // Flip to y-down so coordinates match the design space verbatim.
        ctx.translateBy(x: 0, y: px)
        ctx.scaleBy(x: 1, y: -1)
        ctx.scaleBy(x: px / canvas, y: px / canvas)
        ctx.translateBy(x: gridOffset, y: gridOffset)
        ctx.scaleBy(x: gridScale, y: gridScale)

        tile(ctx, deviceScale: px / canvas)
        chevron(ctx)
        cursor(ctx)
        if !simplified { baseline(ctx) }
    }

    private func tile(_ ctx: CGContext, deviceScale: CGFloat) {
        let path = CGPath(
            roundedRect: CGRect(x: 36, y: 36, width: 440, height: 440),
            cornerWidth: 99, cornerHeight: 99, transform: nil)

        // Shadow needs an opaque fill to cast from; the gradient paints over
        // it. Its offset/blur live in base (device) space, hence deviceScale.
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -12 * deviceScale),
            blur: 24 * deviceScale, color: shadowInk)
        ctx.addPath(path)
        ctx.setFillColor(tileBottom)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let grad = CGGradient(
            colorsSpace: srgb, colors: [tileTop, tileBottom] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(
            grad, start: CGPoint(x: 256, y: 36), end: CGPoint(x: 256, y: 476), options: [])
        ctx.restoreGState()

        ctx.addPath(path)
        ctx.setStrokeColor(tileEdge)
        ctx.setLineWidth(2)
        ctx.strokePath()
    }

    private func chevron(_ ctx: CGContext) {
        ctx.setStrokeColor(mint)
        ctx.setLineWidth(simplified ? 44 : 30)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: CGPoint(x: 150, y: 180))
        ctx.addLine(to: CGPoint(x: 218, y: 256))
        ctx.addLine(to: CGPoint(x: 150, y: 332))
        ctx.strokePath()
    }

    private func cursor(_ ctx: CGContext) {
        let body = CGPath(
            roundedRect: CGRect(x: 258, y: 150, width: 112, height: 212),
            cornerWidth: 24, cornerHeight: 24, transform: nil)
        ctx.addPath(body)
        ctx.setFillColor(cursorTrack)
        ctx.fillPath()

        // Charge level, filled from the bottom: yellow warming into orange.
        ctx.saveGState()
        ctx.addPath(body)
        ctx.clip()
        ctx.clip(to: CGRect(x: 258, y: 254, width: 112, height: 108))
        let grad = CGGradient(
            colorsSpace: srgb, colors: [fuelTop, fuelBottom] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(
            grad, start: CGPoint(x: 314, y: 254), end: CGPoint(x: 314, y: 362), options: [])
        ctx.restoreGState()
    }

    private func baseline(_ ctx: CGContext) {
        ctx.setStrokeColor(baselineInk)
        ctx.setLineWidth(12)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: 150, y: 398))
        ctx.addLine(to: CGPoint(x: 370, y: 398))
        ctx.strokePath()
    }
}

func render(pixels: Int) -> CGImage {
    let ctx = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    Mark(simplified: pixels <= 32).draw(in: ctx, pixels: pixels)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("PNG write failed: \(url.path)") }
}

let ladder: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

let outDir = URL(
    fileURLWithPath: CommandLine.arguments.count > 1
        ? CommandLine.arguments[1] : "AppIcon.iconset")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
for rung in ladder {
    writePNG(render(pixels: rung.pixels), to: outDir.appendingPathComponent("\(rung.name).png"))
}
print("Rendered \(ladder.count) sizes into \(outDir.path)")
