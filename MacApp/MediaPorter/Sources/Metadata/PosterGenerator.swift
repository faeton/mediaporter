// Fallback poster generation via Core Graphics.
// Creates a simple dark poster with the title and year.
// Thread-safe — uses CGContext directly instead of NSImage.lockFocus.

import AppKit
import CoreGraphics
import Foundation

public enum PosterGenerator {
    /// Movie-poster aspect (2:3 portrait). Matches TMDb /poster sizes.
    private static let portraitWidth = 500
    private static let portraitHeight = 750
    /// TV-still aspect (16:9 landscape). Matches TMDb /still sizes and the
    /// per-episode tile in TV.app — text-only fallbacks at this aspect don't
    /// get squished/cropped by the OS.
    private static let landscapeWidth = 1280
    private static let landscapeHeight = 720

    /// Portrait fallback for movies and show-level posters.
    public static func generate(title: String, year: Int? = nil) -> Data? {
        render(title: title, year: year, width: portraitWidth, height: portraitHeight)
    }

    /// Landscape fallback for TV episodes — TV.app's per-episode tile is 16:9
    /// and squishes a 2:3 portrait into an unreadable mess. Use this whenever
    /// the artwork represents an episode, not a show.
    public static func generateLandscape(title: String, year: Int? = nil) -> Data? {
        render(title: title, year: year, width: landscapeWidth, height: landscapeHeight)
    }

    private static func render(title: String, year: Int?, width: Int, height: Int) -> Data? {
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

        // Scale text/padding off the shorter edge so portrait (500×750) keeps
        // its tuned 36pt title and landscape (1280×720) gets a proportional
        // ~52pt instead of looking lost in whitespace.
        let scale = CGFloat(min(width, height)) / 500.0
        let pad: CGFloat = 30 * scale
        let titleSize: CGFloat = 36 * scale
        let yearSize: CGFloat = 22 * scale

        // Flip coordinate system for text drawing
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)

        // Background
        ctx.setFillColor(red: 25/255, green: 25/255, blue: 43/255, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Border
        ctx.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 0.15)
        ctx.setLineWidth(1.5 * scale)
        let borderInset: CGFloat = 8 * scale
        ctx.stroke(CGRect(
            x: borderInset, y: borderInset,
            width: CGFloat(width) - borderInset * 2,
            height: CGFloat(height) - borderInset * 2
        ).insetBy(dx: 0.75 * scale, dy: 0.75 * scale))

        // Use NSGraphicsContext for text rendering (works from any thread with explicit context)
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx

        // Title text
        let titleStyle = NSMutableParagraphStyle()
        titleStyle.alignment = .center
        titleStyle.lineBreakMode = .byWordWrapping

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: titleSize, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: titleStyle,
        ]

        let titleStr = NSAttributedString(string: title, attributes: titleAttrs)
        let maxSize = NSSize(width: CGFloat(width) - pad * 2, height: CGFloat(height))
        let titleBounds = titleStr.boundingRect(with: maxSize, options: [.usesLineFragmentOrigin, .usesFontLeading])

        // Center title vertically (slightly above center)
        let titleY = (CGFloat(height) - titleBounds.height) / 2 - 20 * scale
        titleStr.draw(with: NSRect(
            x: pad, y: titleY,
            width: CGFloat(width) - pad * 2, height: titleBounds.height
        ), options: [.usesLineFragmentOrigin, .usesFontLeading])

        // Year text below title
        if let year {
            let yearAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: yearSize, weight: .light),
                .foregroundColor: NSColor(white: 1, alpha: 0.6),
                .paragraphStyle: titleStyle,
            ]
            let yearStr = NSAttributedString(string: String(year), attributes: yearAttrs)
            yearStr.draw(with: NSRect(
                x: pad, y: titleY + titleBounds.height + 10 * scale,
                width: CGFloat(width) - pad * 2, height: yearSize * 1.4
            ), options: [.usesLineFragmentOrigin])
        }

        NSGraphicsContext.restoreGraphicsState()

        // Convert to JPEG
        guard let cgImage = ctx.makeImage() else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}
