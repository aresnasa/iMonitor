#!/usr/bin/env swift  //  //  generate-app-icon.swift  //  iMonitor
//
//  Renders the AppIcon PNGs from vector geometry on Apple's macOS app-icon
//  grid: an 824 x 824 continuous-corner body centred on a transparent
//  1024 x 1024 canvas, fully opaque inside.
//
//  The old artwork filled the whole canvas edge to edge and was built from
//  translucent layers. macOS 26+ cannot match such an icon to its icon shape,
//  so it places it on a grey plate ("jailed" legacy icon), and the see-through
//  panel picked up whatever was behind it - which is why the icon looked
//  different in Spotlight, Launchpad/Apps, Finder and the Dock. This keeps the
//  same design (frame, panel, CPU/memory/GPU bars, ECG trace) with the colours
//  it showed over white, mapped onto the grid.
//
//  Usage: swift scripts/generate-app-icon.swift [output-dir]
//  (defaults to iMonitor/Assets.xcassets/AppIcon.appiconset)
//

import AppKit
import ImageIO
import SwiftUI

// MARK: - Geometry (1024-point canvas, top-left origin)

/// The original artwork was drawn full-bleed on 1024 x 1024; it is scaled into
/// the grid's 824 x 824 body, which sits 100 pt in from every edge.
let bodyInset: CGFloat = 100
let bodySize: CGFloat = 824
let bodyCornerRadius: CGFloat = 185.4
let artworkScale = bodySize / 1024

func grid(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
    CGPoint(x: bodyInset + x * artworkScale, y: bodyInset + y * artworkScale)
}

func gridRect(_ minX: CGFloat, _ minY: CGFloat, _ maxX: CGFloat, _ maxY: CGFloat) -> CGRect {
    let origin = grid(minX, minY)
    let end = grid(maxX, maxY)
    return CGRect(x: origin.x, y: origin.y, width: end.x - origin.x, height: end.y - origin.y)
}

func color(_ hex: UInt32) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1)
}

func continuousRoundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
}

struct Bar {
    let minX: CGFloat
    let maxX: CGFloat
    let fillTop: CGFloat
    let track: UInt32
    let fill: UInt32
}

let frameColor = color(0x1E2846)
let panelColor = color(0x67728E)
let traceColor = color(0x23E4AD)
let barTop: CGFloat = 205
let barBottom: CGFloat = 667
let barCornerRadius: CGFloat = 32 * artworkScale
// CPU (green), memory (blue), GPU (orange); fill heights as in the original.
let bars = [
    Bar(minX: 184, maxX: 316, fillTop: 343, track: 0xDCF8E1, fill: 0x5EDD73),
    Bar(minX: 446, maxX: 578, fillTop: 435, track: 0xDFF4FE, fill: 0x6ACDFB),
    Bar(minX: 709, maxX: 841, fillTop: 274, track: 0xFFECCF, fill: 0xFFA822),
]

/// The ECG trace: a gentle wave (period 200, amplitude 8 around y = 819.5)
/// with one heartbeat spike in the middle, in the original 1024 coordinates.
func tracePoints() -> [CGPoint] {
    func wave(_ x: CGFloat, troughAt trough: CGFloat) -> CGFloat {
        819.5 + 8 * cos(2 * .pi * (x - trough) / 200)
    }
    var points: [CGPoint] = []
    for x in stride(from: CGFloat(100), through: 370, by: 10) {
        points.append(CGPoint(x: x, y: wave(x, troughAt: 160)))
    }
    // The spike, as traced from the original artwork every 10 points.
    let spike: [CGFloat] = [
        826, 806, 783, 751, 731.5, 726, 733, 753, 779.5, 803.5,
        829.5, 849.5, 860.5, 865.5, 863.5, 853, 841.5, 833.5,
    ]
    for (index, y) in spike.enumerated() {
        points.append(CGPoint(x: 380 + CGFloat(index) * 10, y: y))
    }
    for x in stride(from: CGFloat(560), through: 920, by: 10) {
        points.append(CGPoint(x: x, y: wave(x, troughAt: 770)))
    }
    return points.map { grid($0.x, $0.y) }
}

/// A Catmull-Rom spline through `points`, as cubic Bezier segments.
func smoothPath(through points: [CGPoint]) -> CGPath {
    let path = CGMutablePath()
    guard let first = points.first else { return path }
    path.move(to: first)
    for index in 0..<(points.count - 1) {
        let p0 = points[max(index - 1, 0)]
        let p1 = points[index]
        let p2 = points[index + 1]
        let p3 = points[min(index + 2, points.count - 1)]
        let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
        let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
        path.addCurve(to: p2, control1: c1, control2: c2)
    }
    return path
}

// MARK: - Rendering

func render(pixels: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(pixels) / 1024
    // Draw in the 1024-point canvas with a top-left origin.
    context.translateBy(x: 0, y: CGFloat(pixels))
    context.scaleBy(x: scale, y: -scale)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    let body = CGRect(x: bodyInset, y: bodyInset, width: bodySize, height: bodySize)
    context.addPath(continuousRoundedRect(body, radius: bodyCornerRadius))
    context.setFillColor(frameColor)
    context.fillPath()

    let frameWidth = 61 * artworkScale
    context.addPath(
        continuousRoundedRect(
            body.insetBy(dx: frameWidth, dy: frameWidth),
            radius: bodyCornerRadius - frameWidth))
    context.setFillColor(panelColor)
    context.fillPath()

    for bar in bars {
        context.addPath(
            continuousRoundedRect(
                gridRect(bar.minX, barTop, bar.maxX, barBottom), radius: barCornerRadius))
        context.setFillColor(color(bar.track))
        context.fillPath()
        context.addPath(
            continuousRoundedRect(
                gridRect(bar.minX, bar.fillTop, bar.maxX, barBottom), radius: barCornerRadius))
        context.setFillColor(color(bar.fill))
        context.fillPath()
    }

    // At least one device pixel wide, so the trace survives the small sizes.
    context.setLineWidth(max(16 * artworkScale, 1 / scale))
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setStrokeColor(traceColor)
    context.addPath(smoothPath(through: tracePoints()))
    context.strokePath()

    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil)
    else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

// MARK: - Main

let scriptDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let outputDirectory =
    CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : scriptDirectory.appendingPathComponent("../iMonitor/Assets.xcassets/AppIcon.appiconset")
        .standardizedFileURL

for pixels in [16, 32, 64, 128, 256, 512, 1024] {
    let url = outputDirectory.appendingPathComponent("iMonitor-icon-\(pixels).png")
    try writePNG(render(pixels: pixels), to: url)
    print("wrote \(url.path)")
}
