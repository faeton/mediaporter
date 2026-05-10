// Runtime-rendered dock icon. SwiftPM executables don't ship an
// asset catalog or .icns, so without this the dock shows the
// generic Swift app glyph. We draw a 1024×1024 mark with CoreGraphics
// at launch and feed it to NSApp.applicationIconImage.
//
// Mark concept (from designideas/): black rounded square, pink
// film-strip on the left, pink rounded "device" on the right, pink
// play triangle inside the device. Hand-off arrow curves between
// them. All accent #EC4899.

import AppKit

enum AppIcon {
    static let accent = NSColor(srgbRed: 0xEC / 255.0,
                                green: 0x48 / 255.0,
                                blue: 0x99 / 255.0,
                                alpha: 1.0)
    static let bgTop = NSColor(srgbRed: 0.13, green: 0.13, blue: 0.15, alpha: 1)
    static let bgBottom = NSColor(srgbRed: 0.04, green: 0.04, blue: 0.05, alpha: 1)

    /// Build the icon at the requested edge length and install it on the
    /// running NSApp. Default 1024 is what the Dock + App Switcher want;
    /// AppKit downscales for the menu bar / Mission Control automatically.
    static func install() {
        let img = render(size: 1024)
        NSApp.applicationIconImage = img
    }

    static func render(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }

        guard let ctx = NSGraphicsContext.current?.cgContext else { return image }

        // macOS Big Sur+ icon spec: 1024 canvas, ~824 squircle centered,
        // ~100 transparent padding each side. Without this the tile looks
        // oversized vs system icons in the Dock and App Switcher.
        let tile = size * (824.0 / 1024.0)
        let inset = (size - tile) / 2
        // Apple "squircle" corner radius is ≈22.37% of the tile edge.
        let radius = tile * 0.2237
        let rect = CGRect(x: inset, y: inset, width: tile, height: tile)
        let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        // Background gradient — slight top-down sheen so the flat black
        // doesn't look painted-on at small sizes.
        ctx.saveGState()
        ctx.addPath(squircle)
        ctx.clip()
        let colors = [bgTop.cgColor, bgBottom.cgColor] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: colors,
                                  locations: [0, 1])!
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: rect.maxY),
                               end: CGPoint(x: 0, y: rect.minY),
                               options: [])
        ctx.restoreGState()

        // All foreground geometry uses a normalized 0…1024 coordinate
        // system regardless of the requested size, so callers can render
        // any resolution without retuning numbers. Translate+scale into
        // the inset tile so the artwork respects macOS icon padding.
        let scale = tile / 1024.0
        ctx.saveGState()
        ctx.translateBy(x: inset, y: inset)
        ctx.scaleBy(x: scale, y: scale)

        let pink = accent.cgColor
        ctx.setFillColor(pink)
        ctx.setStrokeColor(pink)

        // ----- Film strip (left source) -----
        // A short pink rectangle with two rows of sprocket holes punched out.
        let stripRect = CGRect(x: 200, y: 312, width: 200, height: 400)
        let stripPath = CGMutablePath()
        stripPath.addRoundedRect(in: stripRect, cornerWidth: 32, cornerHeight: 32, transform: .identity)

        // Holes: 5 rows × 2 columns. EvenOdd fill rule punches them out.
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

        // ----- Device frame (right destination) -----
        // Tall rounded rect, stroked, suggests an iPad/iPhone in portrait.
        let deviceRect = CGRect(x: 600, y: 262, width: 280, height: 500)
        let deviceCorner: CGFloat = 56
        let deviceStroke: CGFloat = 28
        let device = CGPath(roundedRect: deviceRect,
                            cornerWidth: deviceCorner, cornerHeight: deviceCorner,
                            transform: nil)
        ctx.addPath(device)
        ctx.setLineWidth(deviceStroke)
        ctx.strokePath()

        // Play triangle inside the device, centered.
        let triCx = deviceRect.midX + 14   // optical centering nudges right
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

        // ----- Hand-off curve: film → device -----
        // Subtle thick line that arcs from the strip's right edge down
        // and up into the device's left edge. Sells the "porting" idea.
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
}
