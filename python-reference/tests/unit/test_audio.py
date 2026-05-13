"""Tests for audio stream classification."""

from mediaporter.audio import classify_audio_stream, classify_all_audio
from mediaporter.probe import StreamInfo


def _stream(codec="aac", channels=2):
    return StreamInfo(index=1, codec_type="audio", codec_name=codec, channels=channels)


def test_aac_copy():
    action = classify_audio_stream(_stream("aac"))
    assert action.action == "copy"
    assert action.target_codec is None


def test_ac3_transcode():
    # AC3 decodes on iPad but the TV app's audio-language switcher silently
    # drops AC3 tracks from its list, so we transcode them to AAC.
    # See research/docs/AUDIO_SWITCHER_RULE.md.
    action = classify_audio_stream(_stream("ac3"))
    assert action.action == "transcode"
    assert action.target_codec == "aac"

    surround = classify_audio_stream(_stream("ac3", channels=6))
    assert surround.action == "transcode"
    assert surround.target_codec == "aac"
    assert surround.target_channels == 6
    assert surround.target_bitrate == "384k"


def test_eac3_copy():
    action = classify_audio_stream(_stream("eac3"))
    assert action.action == "copy"


def test_mp3_copy():
    action = classify_audio_stream(_stream("mp3"))
    assert action.action == "copy"


def test_dts_stereo_transcode():
    action = classify_audio_stream(_stream("dts", channels=2))
    assert action.action == "transcode"
    assert action.target_codec == "aac"
    assert action.target_channels == 2
    assert action.target_bitrate == "256k"


def test_dts_surround_transcode():
    action = classify_audio_stream(_stream("dts", channels=6))
    assert action.action == "transcode"
    assert action.target_codec == "aac"
    assert action.target_channels == 6
    assert action.target_bitrate == "384k"


def test_dts_71_transcode():
    action = classify_audio_stream(_stream("dts", channels=8))
    assert action.action == "transcode"
    assert action.target_channels == 6
    assert action.target_bitrate == "384k"


def test_classify_all():
    streams = [_stream("aac"), _stream("dts", 6)]
    actions = classify_all_audio(streams)
    assert len(actions) == 2
    assert actions[0].action == "copy"
    assert actions[1].action == "transcode"
