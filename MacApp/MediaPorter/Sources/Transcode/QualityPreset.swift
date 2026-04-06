// Encoding quality presets for ffmpeg transcoding.

import Foundation

struct QualityPreset {
    let name: String
    let crf: Int            // libx265 CRF value
    let preset: String      // libx265 preset (fast/medium/slow)
    let vtQuality: Int      // VideoToolbox quality (1-100)
}

extension QualityPreset {
    static let fast = QualityPreset(name: "fast", crf: 28, preset: "fast", vtQuality: 55)
    static let balanced = QualityPreset(name: "balanced", crf: 23, preset: "medium", vtQuality: 65)
    static let quality = QualityPreset(name: "quality", crf: 18, preset: "slow", vtQuality: 75)

    static func named(_ name: String) -> QualityPreset {
        switch name.lowercased() {
        case "fast": return .fast
        case "quality": return .quality
        default: return .balanced
        }
    }
}
