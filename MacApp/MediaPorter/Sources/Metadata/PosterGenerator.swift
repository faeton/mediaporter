// Fallback poster generation via Core Graphics.
// Creates a simple dark poster with the title and year.
// Thread-safe — uses CGContext directly instead of NSImage.lockFocus.

import AppKit
import CoreGraphics
import Foundation

enum PosterGenerator {
    private static let width = 500
    private static let height = 750

    /// Generate a fallback poster JPEG with title and optional year.
    static func generate(title: String, year: Int? = nil) -> Data? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }

        // Flip coordinate system for text drawing
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)

        // Background
        ctx.setFillColor(red: 25/255, green: 25/255, blue: 43/255, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Border
        ctx.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 0.15)
        ctx.setLineWidth(1.5)
        ctx.stroke(CGRect(x: 8, y: 8, width: width - 16, height: height - 16).insetBy(dx: 0.75, dy: 0.75))

        // Use NSGraphicsContext for text rendering (works from any thread with explicit context)
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx

        // Title text
        let titleStyle = NSMutableParagraphStyle()
        titleStyle.alignment = .center
        titleStyle.lineBreakMode = .byWordWrapping

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 36, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: titleStyle,
        ]

        let titleStr = NSAttributedString(string: title, attributes: titleAttrs)
        let maxSize = NSSize(width: CGFloat(width) - 60, height: CGFloat(height))
        let titleBounds = titleStr.boundingRect(with: maxSize, options: [.usesLineFragmentOrigin, .usesFontLeading])

        // Center title vertically (slightly above center)
        let titleY = (CGFloat(height) - titleBounds.height) / 2 - 20
        titleStr.draw(with: NSRect(
            x: 30, y: titleY,
            width: CGFloat(width) - 60, height: titleBounds.height
        ), options: [.usesLineFragmentOrigin, .usesFontLeading])

        // Year text below title
        if let year {
            let yearAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 22, weight: .light),
                .foregroundColor: NSColor(white: 1, alpha: 0.6),
                .paragraphStyle: titleStyle,
            ]
            let yearStr = NSAttributedString(string: String(year), attributes: yearAttrs)
            yearStr.draw(with: NSRect(
                x: 30, y: titleY + titleBounds.height + 10,
                width: CGFloat(width) - 60, height: 30
            ), options: [.usesLineFragmentOrigin])
        }

        NSGraphicsContext.restoreGraphicsState()

        // Convert to JPEG
        guard let cgImage = ctx.makeImage() else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}
