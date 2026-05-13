// Standalone icon generator. Renders the same artwork as AppIcon.swift but
// writes PNGs at all macOS icon sizes to a .iconset directory, so we can
// `iconutil -c icns` the result into a shippable AppIcon.icns.
//
// Run via scripts/make-icon.sh (which wraps iconutil afterwards).
//
// Keep the render logic in sync with App/Sources/AppIcon.swift. Two copies
// is annoying but linking a build-time tool to the app's render code would
// require restructuring (a shared module just for icon drawing). One-off
// script is cheaper.

import AppKit
import Foundation

let accent = NSColor(srgbRed: 0xEC / 255.0, green: 0x48 / 255.0, blue: 0x99 / 255.0, alpha: 1)
let bgTop = NSColor(srgbRed: 0.13, green: 0.13, blue: 0.15, alpha: 1)
let bgBottom = NSColor(srgbRed: 0.04, green: 0.04, blue: 0.05, alpha: 1)

func render(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    guard let ctx = NSGraphicsContext.current?.cgContext else { return image }

    let tile = size * (824.0 / 1024.0)
    let inset = (size - tile) / 2
    let radius = tile * 0.2237
    let rect = CGRect(x: inset, y: inset, width: tile, height: tile)
    let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let colors = [bgTop.cgColor, bgBottom.cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: rect.maxY),
                           end: CGPoint(x: 0, y: rect.minY),
                           options: [])
    ctx.restoreGState()

    let scale = tile / 1024.0
    ctx.saveGState()
    ctx.translateBy(x: inset, y: inset)
    ctx.scaleBy(x: scale, y: scale)

    let pink = accent.cgColor
    ctx.setFillColor(pink)
    ctx.setStrokeColor(pink)

    // Film strip with sprocket holes
    let stripRect = CGRect(x: 200, y: 312, width: 200, height: 400)
    let stripPath = CGMutablePath()
    stripPath.addRoundedRect(in: stripRect, cornerWidth: 32, cornerHeight: 32, transform: .identity)
    let holeWidth: CGFloat = 28
    let holeHeight: CGFloat = 36
    let holeXs: [CGFloat] = [stripRect.minX + 22, stripRect.maxX - 22 - holeWidth]
    let rowCount = 5
    let firstY = stripRect.minY + 36
    let stride = (stripRect.height - 72 - holeHeight) / CGFloat(rowCount - 1)
    for r in 0..<rowCount {
        let y = firstY + CGFloat(r) * stride
        for x in holeXs {
            stripPath.addRoundedRect(
                in: CGRect(x: x, y: y, width: holeWidth, height: holeHeight),
                cornerWidth: 6, cornerHeight: 6, transform: .identity
            )
        }
    }
    ctx.addPath(stripPath)
    ctx.fillPath(using: .evenOdd)

    // Device silhouette
    let deviceRect = CGRect(x: 600, y: 262, width: 280, height: 500)
    let device = CGPath(roundedRect: deviceRect, cornerWidth: 56, cornerHeight: 56, transform: nil)
    ctx.addPath(device)
    ctx.setLineWidth(28)
    ctx.strokePath()

    // Play triangle
    let triCx = deviceRect.midX + 14
    let triCy = deviceRect.midY
    let triH: CGFloat = 180
    let triW: CGFloat = triH * 0.866
    let tri = CGMutablePath()
    tri.move(to: CGPoint(x: triCx + triW / 2, y: triCy))
    tri.addLine(to: CGPoint(x: triCx - triW / 2, y: triCy + triH / 2))
    tri.addLine(to: CGPoint(x: triCx - triW / 2, y: triCy - triH / 2))
    tri.closeSubpath()
    ctx.addPath(tri)
    ctx.fillPath()

    // Hand-off curve
    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.setLineWidth(28)
    let curve = CGMutablePath()
    let startP = CGPoint(x: stripRect.maxX - 4, y: stripRect.midY)
    let endP = CGPoint(x: deviceRect.minX + 4, y: deviceRect.midY)
    curve.move(to: startP)
    curve.addCurve(
        to: endP,
        control1: CGPoint(x: startP.x + 70, y: startP.y - 90),
        control2: CGPoint(x: endP.x - 70, y: endP.y + 90)
    )
    ctx.addPath(curve)
    ctx.strokePath()
    ctx.restoreGState()

    ctx.restoreGState()
    return image
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make-icon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "PNG encode failed for \(url.lastPathComponent)"])
    }
    try png.write(to: url)
}

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write("usage: make-icon.swift <output-iconset-dir>\n".data(using: .utf8)!)
    exit(2)
}

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.removeItem(at: outDir)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// Standard macOS .iconset sizes per Apple's HIG.
// Each entry: (logical size, scale factor → filename).
let entries: [(Int, Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]

for (logical, scale) in entries {
    let actual = logical * scale
    let suffix = scale == 1 ? "" : "@2x"
    let name = "icon_\(logical)x\(logical)\(suffix).png"
    let image = render(size: CGFloat(actual))
    try writePNG(image, to: outDir.appendingPathComponent(name))
    print("wrote \(name) (\(actual)×\(actual))")
}

print("iconset written to \(outDir.path)")
