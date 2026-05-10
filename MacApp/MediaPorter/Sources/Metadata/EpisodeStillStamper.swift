// Burn the episode number into the upper-left of an episode still so the
// iPad TV.app's 16:9 tile communicates *which* episode it is. Random
// extracted frames don't carry episode meaning on their own, and even
// TMDb stills repeat (compilation episodes, recap clips), so the number
// disambiguates faster than visually scanning thumbnails.

import AppKit

enum EpisodeStillStamper {

    /// Render `label` (e.g. "E01", "S2·E03") into the upper-left corner of
    /// `imageData`. Returns JPEG bytes at quality 0.92. Returns the input
    /// unchanged if decoding fails — we'd rather ship the un-stamped still
    /// than fail the sync over a cosmetic overlay.
    static func stamp(_ imageData: Data, label: String) -> Data {
        guard let source = NSImage(data: imageData),
              let cgSource = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return imageData
        }
        let width = cgSource.width
        let height = cgSource.height

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return imageData }

        ctx.draw(cgSource, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Scale type by image height so the burn-in reads the same on a
        // 1280×720 TMDb still and a 1920×1080 ffmpeg extraction.
        let fontSize = CGFloat(height) * 0.16
        let inset = CGFloat(height) * 0.05

        // Scrim gradient behind the text — keeps it readable on bright
        // frames (e.g. snowy/sky shots) without darkening the whole image.
        ctx.saveGState()
        let gradHeight = fontSize * 2.4
        let scrimRect = CGRect(x: 0, y: CGFloat(height) - gradHeight,
                               width: CGFloat(width) * 0.55, height: gradHeight)
        let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [
                CGColor(red: 0, green: 0, blue: 0, alpha: 0.55),
                CGColor(red: 0, green: 0, blue: 0, alpha: 0.0),
            ] as CFArray,
            locations: [0, 1]
        )!
        ctx.clip(to: scrimRect)
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: scrimRect.minX, y: scrimRect.maxY),
            end: CGPoint(x: scrimRect.maxX, y: scrimRect.minY),
            options: []
        )
        ctx.restoreGState()

        // Text. CGContext text origin is bottom-left, so y = height - inset - fontSize.
        ctx.saveGState()
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .heavy),
            .foregroundColor: NSColor.white,
            .strokeColor: NSColor.black.withAlphaComponent(0.7),
            // Negative width = fill *and* stroke (positive = stroke only).
            .strokeWidth: -3.0,
        ]
        let str = NSAttributedString(string: label, attributes: attrs)
        let textY = CGFloat(height) - inset - fontSize * 1.05
        str.draw(at: CGPoint(x: inset, y: textY))

        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()

        guard let stamped = ctx.makeImage() else { return imageData }
        let rep = NSBitmapImageRep(cgImage: stamped)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92]) ?? imageData
    }
}
