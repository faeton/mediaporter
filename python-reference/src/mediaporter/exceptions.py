"""Custom exceptions for mediaporter."""


class MediaPorterError(Exception):
    """Base exception for all mediaporter errors."""


class ProbeError(MediaPorterError):
    """Failed to probe media file with ffprobe."""


class TranscodeError(MediaPorterError):
    """FFmpeg transcoding failed."""


class SubtitleError(MediaPorterError):
    """Subtitle processing failed."""


class MetadataError(MediaPorterError):
    """Metadata lookup or embedding failed."""


class DeviceError(MediaPorterError):
    """iOS device communication failed."""


class DeviceNotFoundError(DeviceError):
    """No iOS device connected or detected."""


class TransferError(MediaPorterError):
    """File transfer to device failed."""


class SyncError(MediaPorterError):
    """ATC sync protocol failed."""
