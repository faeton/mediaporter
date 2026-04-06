// Audio track classification — decide copy vs transcode per audio stream.

import Foundation

struct AudioAction {
    let stream: StreamInfo
    let action: String          // "copy" or "transcode"
    let targetCodec: String?    // nil if copy
    let targetChannels: Int?
    let targetBitrate: String?  // e.g. "256k", "384k"
}

/// Classify a single audio stream for iPad compatibility.
func classifyAudioStream(_ stream: StreamInfo) -> AudioAction {
    if CodecSets.compatibleAudio.contains(stream.codecName) {
        return AudioAction(stream: stream, action: "copy",
                           targetCodec: nil, targetChannels: nil, targetBitrate: nil)
    }
    let channels = stream.channels ?? 2
    if channels >= 6 {
        return AudioAction(stream: stream, action: "transcode",
                           targetCodec: "aac", targetChannels: 6, targetBitrate: "384k")
    }
    return AudioAction(stream: stream, action: "transcode",
                       targetCodec: "aac", targetChannels: 2, targetBitrate: "256k")
}

/// Classify all audio streams.
func classifyAllAudio(_ streams: [StreamInfo]) -> [AudioAction] {
    streams.map { classifyAudioStream($0) }
}
