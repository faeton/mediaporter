// Encoding quality presets for ffmpeg transcoding.

import Foundation

public struct QualityPreset {
    public let name: String
    public let crf: Int            // libx265 CRF value
    public let preset: String      // libx265 preset (fast/medium/slow)
    public let vtQuality: Int      // VideoToolbox quality (1-100)

    public init(name: String, crf: Int, preset: String, vtQuality: Int) {
        self.name = name
        self.crf = crf
        self.preset = preset
        self.vtQuality = vtQuality
    }
}

extension QualityPreset {
    public static let fast = QualityPreset(name: "fast", crf: 28, preset: "fast", vtQuality: 55)
    public static let balanced = QualityPreset(name: "balanced", crf: 23, preset: "medium", vtQuality: 65)
    public static let quality = QualityPreset(name: "quality", crf: 18, preset: "slow", vtQuality: 75)

    public static func named(_ name: String) -> QualityPreset {
        switch name.lowercased() {
        case "fast": return .fast
        case "quality": return .quality
        default: return .balanced
        }
    }
}
