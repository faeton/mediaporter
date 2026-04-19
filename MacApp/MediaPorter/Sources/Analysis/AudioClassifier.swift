// Audio track classification — decide copy vs transcode per audio stream.

import Foundation

public struct AudioAction {
    public let stream: StreamInfo
    public let action: String          // "copy" or "transcode"
    public let targetCodec: String?    // nil if copy
    public let targetChannels: Int?
    public let targetBitrate: String?  // e.g. "256k", "384k"

    public init(
        stream: StreamInfo,
        action: String,
        targetCodec: String? = nil,
        targetChannels: Int? = nil,
        targetBitrate: String? = nil
    ) {
        self.stream = stream
        self.action = action
        self.targetCodec = targetCodec
        self.targetChannels = targetChannels
        self.targetBitrate = targetBitrate
    }
}

/// Classify a single audio stream for iPad compatibility.
public func classifyAudioStream(_ stream: StreamInfo) -> AudioAction {
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
public func classifyAllAudio(_ streams: [StreamInfo]) -> [AudioAction] {
    streams.map { classifyAudioStream($0) }
}
