// Mirrors tests/unit/test_compat.py for Swift Core.
// Baseline: pins CURRENT behavior before Phase 1. Once we port the 0.3.2
// audio-switcher rule, the AC3 assertions flip and this file gets updated
// in lockstep with Compatibility.swift.

import XCTest
@testable import MediaPorterCore

private func mediaInfo(
    videoCodec: String = "hevc",
    audioCodec: String = "aac",
    format: String = "matroska,webm",
    subCodec: String? = nil
) -> MediaInfo {
    var video: [StreamInfo] = [
        StreamInfo(index: 0, codecType: "video", codecName: videoCodec, width: 1920, height: 1080)
    ]
    var audio: [StreamInfo] = [
        StreamInfo(index: 1, codecType: "audio", codecName: audioCodec, channels: 2)
    ]
    var subs: [StreamInfo] = []
    if let s = subCodec {
        subs = [StreamInfo(index: 2, codecType: "subtitle", codecName: s)]
    }
    _ = video
    _ = audio
    return MediaInfo(
        path: URL(fileURLWithPath: "/tmp/test.mkv"),
        formatName: format,
        duration: 100.0,
        videoStreams: video,
        audioStreams: audio,
        subtitleStreams: subs
    )
}

final class CompatibilityTests: XCTestCase {
    func testH264Copy() {
        let d = evaluateCompatibility(mediaInfo: mediaInfo(videoCodec: "h264"))
        XCTAssertEqual(d.streamActions[0], "copy")
        XCTAssertFalse(d.needsTranscode)
    }

    func testHEVCCopy() {
        let d = evaluateCompatibility(mediaInfo: mediaInfo(videoCodec: "hevc"))
        XCTAssertEqual(d.streamActions[0], "copy")
    }

    func testVP9Transcode() {
        let d = evaluateCompatibility(mediaInfo: mediaInfo(videoCodec: "vp9"))
        XCTAssertEqual(d.streamActions[0], "transcode")
        XCTAssertTrue(d.needsTranscode)
    }

    func testAV1Transcode() {
        let d = evaluateCompatibility(mediaInfo: mediaInfo(videoCodec: "av1"))
        XCTAssertEqual(d.streamActions[0], "transcode")
    }

    func testAACCopy() {
        let d = evaluateCompatibility(mediaInfo: mediaInfo(audioCodec: "aac"))
        XCTAssertEqual(d.streamActions[1], "copy")
    }

    // Post-0.3.2 rule: AC3 must transcode because the iPad TV app drops AC3
    // from the audio-language switcher (see research/docs/AUDIO_SWITCHER_RULE.md).
    func testAC3Transcodes() {
        let d = evaluateCompatibility(mediaInfo: mediaInfo(audioCodec: "ac3"))
        XCTAssertEqual(d.streamActions[1], "transcode")
        XCTAssertTrue(d.needsTranscode)
    }

    func testEAC3Copy() {
        let d = evaluateCompatibility(mediaInfo: mediaInfo(audioCodec: "eac3"))
        XCTAssertEqual(d.streamActions[1], "copy")
    }

    func testDTSTranscode() {
        let d = evaluateCompatibility(mediaInfo: mediaInfo(audioCodec: "dts"))
        XCTAssertEqual(d.streamActions[1], "transcode")
        XCTAssertTrue(d.needsTranscode)
    }

    func testMP4NoRemux() {
        let d = evaluateCompatibility(mediaInfo: mediaInfo(format: "mov,mp4,m4a,3gp,3g2,mj2"))
        XCTAssertFalse(d.needsRemux)
    }

    func testMKVNeedsRemux() {
        let d = evaluateCompatibility(mediaInfo: mediaInfo(format: "matroska,webm"))
        XCTAssertTrue(d.needsRemux)
    }

    func testSRTConvert() {
        let d = evaluateCompatibility(mediaInfo: mediaInfo(subCodec: "subrip"))
        XCTAssertEqual(d.streamActions[2], "convert_to_mov_text")
    }

    func testPGSSkip() {
        let d = evaluateCompatibility(mediaInfo: mediaInfo(subCodec: "hdmv_pgs_subtitle"))
        XCTAssertEqual(d.streamActions[2], "skip")
    }

    func testMovTextCopy() {
        let d = evaluateCompatibility(mediaInfo: mediaInfo(subCodec: "mov_text"))
        XCTAssertEqual(d.streamActions[2], "copy")
    }

    func testHDFlag1080p() {
        XCTAssertEqual(getHDFlag(width: 1920, height: 1080), 2)
    }

    func testHDFlag720p() {
        XCTAssertEqual(getHDFlag(width: 1280, height: 720), 1)
    }

    func testHDFlagSD() {
        XCTAssertEqual(getHDFlag(width: 720, height: 480), 0)
    }

    func testHDFlagNone() {
        XCTAssertEqual(getHDFlag(width: nil, height: nil), 0)
    }

    func testHDFlag4K() {
        XCTAssertEqual(getHDFlag(width: 3840, height: 2160), 2)
    }
}
