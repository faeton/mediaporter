// Extract a representative landscape still from a video file via ffmpeg.
// Used as a fallback when TMDb has no `still_path` for an episode (anime
// releases, obscure shows, anything pre-airing) so the per-episode tile in
// TV.app gets a proper 16:9 frame instead of the squished show portrait.
//
// Strategy: skip the first 5% of duration (intros, black frames, studio
// cards), sample 3 candidate frames at distinct offsets, pick the brightest.
// "Brightest" is a cheap proxy for "not a fade/black/title card" — works
// well in practice and is much simpler than scene-change detection.

import AppKit
import CoreGraphics
import Foundation

public enum StillExtractor {
    private static let outputWidth = 1280
    private static let outputHeight = 720
    private static let postIntroSkipFraction = 0.05
    /// Sample offsets into the post-intro window. Spread across the middle of
    /// the file so we don't catch end-credits either.
    private static let sampleFractions = [0.10, 0.40, 0.70]

    /// Extract a 1280×720 JPEG from `url`. Returns nil if ffmpeg is missing,
    /// the duration is unknown/too short, or every candidate frame fails to
    /// decode. `duration` is in seconds — pass the value from `MediaInfo`.
    public static func extract(from url: URL, duration: TimeInterval) async -> Data? {
        guard let ffmpeg = FFmpegLocator.ffmpeg else { return nil }
        // Files <30 s aren't really episodes; skip rather than risk grabbing
        // intro-card-only content.
        guard duration > 30 else { return nil }

        let postIntroStart = duration * postIntroSkipFraction
        let postIntroSpan = duration - postIntroStart

        var bestData: Data? = nil
        var bestLuma: Double = -1

        for fraction in sampleFractions {
            let offset = postIntroStart + postIntroSpan * fraction
            guard let data = await extractFrame(ffmpeg: ffmpeg, url: url, atSeconds: offset) else {
                continue
            }
            let luma = averageLuma(data)
            if luma > bestLuma {
                bestLuma = luma
                bestData = data
            }
        }

        // Reject obviously-black candidates (all three samples were near-black).
        // The synthetic landscape fallback is a better outcome than uploading
        // a black rectangle.
        guard let bestData, bestLuma > 0.05 else { return nil }
        return bestData
    }

    private static func extractFrame(
        ffmpeg: URL, url: URL, atSeconds offset: TimeInterval
    ) async -> Data? {
        // Write to a unique temp file rather than piping stdout — ffmpeg's
        // mjpeg muxer writes a header only at finalize, and stdout pipes can
        // close mid-write on slow filesystems. Temp file is reliable.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp-still-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let proc = Process()
        proc.executableURL = ffmpeg
        // -ss BEFORE -i for fast keyframe seek; -frames:v 1 grabs one frame;
        // scale forces 1280×720 with black pad to keep aspect honest for
        // odd source ratios. -y overwrites if the temp name collides.
        proc.arguments = [
            "-y",
            "-ss", String(offset),
            "-i", url.path,
            "-frames:v", "1",
            "-vf", "scale=\(outputWidth):\(outputHeight):force_original_aspect_ratio=decrease,pad=\(outputWidth):\(outputHeight):(ow-iw)/2:(oh-ih)/2:black",
            "-q:v", "3",  // high-quality JPEG (~80%)
            tmp.path,
        ]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice

        // Install the handler BEFORE run(): if we set it after, a fast
        // ffmpeg invocation (single-frame seek can be <100 ms on local SSD)
        // can finish before the handler is installed and the continuation
        // never resumes — analyze hangs forever.
        return await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            proc.terminationHandler = { p in
                guard p.terminationStatus == 0 else {
                    cont.resume(returning: nil)
                    return
                }
                cont.resume(returning: try? Data(contentsOf: tmp))
            }
            do {
                try proc.run()
            } catch {
                proc.terminationHandler = nil
                cont.resume(returning: nil)
            }
        }
    }

    /// Average luma of a JPEG in [0, 1]. Sub-samples on a coarse grid (~1024
    /// pixels) — enough to distinguish "mostly dark" from "mostly normal"
    /// without decoding every pixel.
    private static func averageLuma(_ jpeg: Data) -> Double {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return 0
        }
        let w = img.width
        let h = img.height
        guard w > 0, h > 0 else { return 0 }

        // Render into a small RGBA buffer (32×18 ~= 576 samples) for speed.
        let sampleW = 32, sampleH = 18
        var buf = [UInt8](repeating: 0, count: sampleW * sampleH * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &buf, width: sampleW, height: sampleH,
            bitsPerComponent: 8, bytesPerRow: sampleW * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return 0 }
        ctx.interpolationQuality = .low
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: sampleW, height: sampleH))

        // Rec.601 luma. Good enough for a brightness heuristic; we don't need
        // perceptual accuracy.
        var sum = 0.0
        for i in stride(from: 0, to: buf.count, by: 4) {
            let r = Double(buf[i]) / 255
            let g = Double(buf[i + 1]) / 255
            let b = Double(buf[i + 2]) / 255
            sum += 0.299 * r + 0.587 * g + 0.114 * b
        }
        return sum / Double(sampleW * sampleH)
    }
}
