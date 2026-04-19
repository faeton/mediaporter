// Mirrors tests/unit/test_audio.py for Swift Core.
// Baseline: pins CURRENT behavior before Phase 1.

import XCTest
@testable import MediaPorterCore

private func stream(_ codec: String = "aac", channels: Int = 2) -> StreamInfo {
    StreamInfo(index: 1, codecType: "audio", codecName: codec, channels: channels)
}

final class AudioClassifierTests: XCTestCase {
    func testAACCopy() {
        let a = classifyAudioStream(stream("aac"))
        XCTAssertEqual(a.action, "copy")
        XCTAssertNil(a.targetCodec)
    }

    // BASELINE: AC3 currently copies. Phase 1 flips this to "transcode" → aac.
    func testAC3CopyBaseline() {
        let a = classifyAudioStream(stream("ac3"))
        XCTAssertEqual(a.action, "copy")
    }

    func testEAC3Copy() {
        let a = classifyAudioStream(stream("eac3"))
        XCTAssertEqual(a.action, "copy")
    }

    func testMP3Copy() {
        let a = classifyAudioStream(stream("mp3"))
        XCTAssertEqual(a.action, "copy")
    }

    func testDTSStereoTranscode() {
        let a = classifyAudioStream(stream("dts", channels: 2))
        XCTAssertEqual(a.action, "transcode")
        XCTAssertEqual(a.targetCodec, "aac")
        XCTAssertEqual(a.targetChannels, 2)
        XCTAssertEqual(a.targetBitrate, "256k")
    }

    func testDTSSurroundTranscode() {
        let a = classifyAudioStream(stream("dts", channels: 6))
        XCTAssertEqual(a.action, "transcode")
        XCTAssertEqual(a.targetCodec, "aac")
        XCTAssertEqual(a.targetChannels, 6)
        XCTAssertEqual(a.targetBitrate, "384k")
    }

    func testDTS71Transcode() {
        let a = classifyAudioStream(stream("dts", channels: 8))
        XCTAssertEqual(a.action, "transcode")
        // AudioClassifier clamps 7.1 to 6 channels.
        XCTAssertEqual(a.targetChannels, 6)
        XCTAssertEqual(a.targetBitrate, "384k")
    }

    func testClassifyAll() {
        let actions = classifyAllAudio([stream("aac"), stream("dts", channels: 6)])
        XCTAssertEqual(actions.count, 2)
        XCTAssertEqual(actions[0].action, "copy")
        XCTAssertEqual(actions[1].action, "transcode")
    }
}
