"""iOS device discovery via MobileDevice.framework.

Uses AMDeviceNotificationSubscribe + CFRunLoop polling to find connected devices.
Source: scripts/atc_nodeps_sync.py lines 218-233.
"""

from __future__ import annotations

from ctypes import POINTER, byref, c_void_p, cast
from dataclasses import dataclass

from mediaporter.exceptions import DeviceNotFoundError
from mediaporter.sync.frameworks import (
    AMDeviceNotificationCallback,
    cfnumber_to_int,
    cfstr,
    cfstr_to_str,
    get_cf,
    get_cf_constants,
    get_md,
)


# ProductType → (friendly name, native display resolution)
# Covers common iPads and iPhones from roughly 2019 onward. Falls back to
# showing the raw ProductType for anything not in the table.
_DEVICE_MODELS: dict[str, tuple[str, str]] = {
    # iPads
    "iPad7,1": ("iPad Pro 12.9\" (2nd gen)", "2732x2048"),
    "iPad7,2": ("iPad Pro 12.9\" (2nd gen)", "2732x2048"),
    "iPad7,3": ("iPad Pro 10.5\"", "2224x1668"),
    "iPad7,4": ("iPad Pro 10.5\"", "2224x1668"),
    "iPad7,5": ("iPad (6th gen)", "2048x1536"),
    "iPad7,6": ("iPad (6th gen)", "2048x1536"),
    "iPad7,11": ("iPad (7th gen)", "2160x1620"),
    "iPad7,12": ("iPad (7th gen)", "2160x1620"),
    "iPad8,1": ("iPad Pro 11\" (1st gen)", "2388x1668"),
    "iPad8,2": ("iPad Pro 11\" (1st gen)", "2388x1668"),
    "iPad8,3": ("iPad Pro 11\" (1st gen)", "2388x1668"),
    "iPad8,4": ("iPad Pro 11\" (1st gen)", "2388x1668"),
    "iPad8,5": ("iPad Pro 12.9\" (3rd gen)", "2732x2048"),
    "iPad8,6": ("iPad Pro 12.9\" (3rd gen)", "2732x2048"),
    "iPad8,7": ("iPad Pro 12.9\" (3rd gen)", "2732x2048"),
    "iPad8,8": ("iPad Pro 12.9\" (3rd gen)", "2732x2048"),
    "iPad8,9": ("iPad Pro 11\" (2nd gen)", "2388x1668"),
    "iPad8,10": ("iPad Pro 11\" (2nd gen)", "2388x1668"),
    "iPad8,11": ("iPad Pro 12.9\" (4th gen)", "2732x2048"),
    "iPad8,12": ("iPad Pro 12.9\" (4th gen)", "2732x2048"),
    "iPad11,1": ("iPad mini (5th gen)", "2048x1536"),
    "iPad11,2": ("iPad mini (5th gen)", "2048x1536"),
    "iPad11,3": ("iPad Air (3rd gen)", "2224x1668"),
    "iPad11,4": ("iPad Air (3rd gen)", "2224x1668"),
    "iPad11,6": ("iPad (8th gen)", "2160x1620"),
    "iPad11,7": ("iPad (8th gen)", "2160x1620"),
    "iPad12,1": ("iPad (9th gen)", "2160x1620"),
    "iPad12,2": ("iPad (9th gen)", "2160x1620"),
    "iPad13,1": ("iPad Air (4th gen)", "2360x1640"),
    "iPad13,2": ("iPad Air (4th gen)", "2360x1640"),
    "iPad13,4": ("iPad Pro 11\" (3rd gen)", "2388x1668"),
    "iPad13,5": ("iPad Pro 11\" (3rd gen)", "2388x1668"),
    "iPad13,6": ("iPad Pro 11\" (3rd gen)", "2388x1668"),
    "iPad13,7": ("iPad Pro 11\" (3rd gen)", "2388x1668"),
    "iPad13,8": ("iPad Pro 12.9\" (5th gen)", "2732x2048"),
    "iPad13,9": ("iPad Pro 12.9\" (5th gen)", "2732x2048"),
    "iPad13,10": ("iPad Pro 12.9\" (5th gen)", "2732x2048"),
    "iPad13,11": ("iPad Pro 12.9\" (5th gen)", "2732x2048"),
    "iPad13,16": ("iPad Air (5th gen)", "2360x1640"),
    "iPad13,17": ("iPad Air (5th gen)", "2360x1640"),
    "iPad13,18": ("iPad (10th gen)", "2360x1640"),
    "iPad13,19": ("iPad (10th gen)", "2360x1640"),
    "iPad14,1": ("iPad mini (6th gen)", "2266x1488"),
    "iPad14,2": ("iPad mini (6th gen)", "2266x1488"),
    "iPad14,3": ("iPad Pro 11\" (4th gen)", "2388x1668"),
    "iPad14,4": ("iPad Pro 11\" (4th gen)", "2388x1668"),
    "iPad14,5": ("iPad Pro 12.9\" (6th gen)", "2732x2048"),
    "iPad14,6": ("iPad Pro 12.9\" (6th gen)", "2732x2048"),
    "iPad14,8": ("iPad Air 11\" (M2)", "2360x1640"),
    "iPad14,9": ("iPad Air 11\" (M2)", "2360x1640"),
    "iPad14,10": ("iPad Air 13\" (M2)", "2732x2048"),
    "iPad14,11": ("iPad Air 13\" (M2)", "2732x2048"),
    "iPad16,3": ("iPad Pro 11\" (M4)", "2420x1668"),
    "iPad16,4": ("iPad Pro 11\" (M4)", "2420x1668"),
    "iPad16,5": ("iPad Pro 13\" (M4)", "2752x2064"),
    "iPad16,6": ("iPad Pro 13\" (M4)", "2752x2064"),
    # iPhones
    "iPhone11,2": ("iPhone XS", "2436x1125"),
    "iPhone11,4": ("iPhone XS Max", "2688x1242"),
    "iPhone11,6": ("iPhone XS Max", "2688x1242"),
    "iPhone11,8": ("iPhone XR", "1792x828"),
    "iPhone12,1": ("iPhone 11", "1792x828"),
    "iPhone12,3": ("iPhone 11 Pro", "2436x1125"),
    "iPhone12,5": ("iPhone 11 Pro Max", "2688x1242"),
    "iPhone12,8": ("iPhone SE (2nd gen)", "1334x750"),
    "iPhone13,1": ("iPhone 12 mini", "2340x1080"),
    "iPhone13,2": ("iPhone 12", "2532x1170"),
    "iPhone13,3": ("iPhone 12 Pro", "2532x1170"),
    "iPhone13,4": ("iPhone 12 Pro Max", "2778x1284"),
    "iPhone14,2": ("iPhone 13 Pro", "2532x1170"),
    "iPhone14,3": ("iPhone 13 Pro Max", "2778x1284"),
    "iPhone14,4": ("iPhone 13 mini", "2340x1080"),
    "iPhone14,5": ("iPhone 13", "2532x1170"),
    "iPhone14,6": ("iPhone SE (3rd gen)", "1334x750"),
    "iPhone14,7": ("iPhone 14", "2532x1170"),
    "iPhone14,8": ("iPhone 14 Plus", "2778x1284"),
    "iPhone15,2": ("iPhone 14 Pro", "2556x1179"),
    "iPhone15,3": ("iPhone 14 Pro Max", "2796x1290"),
    "iPhone15,4": ("iPhone 15", "2556x1179"),
    "iPhone15,5": ("iPhone 15 Plus", "2796x1290"),
    "iPhone16,1": ("iPhone 15 Pro", "2556x1179"),
    "iPhone16,2": ("iPhone 15 Pro Max", "2796x1290"),
    "iPhone17,1": ("iPhone 16 Pro", "2622x1206"),
    "iPhone17,2": ("iPhone 16 Pro Max", "2868x1320"),
    "iPhone17,3": ("iPhone 16", "2556x1179"),
    "iPhone17,4": ("iPhone 16 Plus", "2796x1290"),
}


def describe_model(product_type: str | None) -> tuple[str, str | None]:
    """Resolve a ProductType string to (friendly name, native resolution).

    Returns (product_type, None) as a fallback if the model is unknown.
    """
    if not product_type:
        return ("Unknown", None)
    entry = _DEVICE_MODELS.get(product_type)
    if entry:
        return entry
    return (product_type, None)


def optimal_transcode_resolution(product_type: str | None) -> str:
    """Suggest a transcode target resolution for the given device.

    mediaporter targets the TV app, which displays MP4 files with video copy.
    On every shipped iPad/iPhone, 1080p plays natively in the TV app with
    hardware decode and is indistinguishable from 2K+ source at typical
    viewing distances — so 1080p is the sweet spot for file size vs quality.
    """
    return "1920x1080 (1080p H.264/HEVC)"


@dataclass
class DeviceInfo:
    """Connected iOS device."""
    udid: str
    handle: c_void_p
    name: str | None = None
    product_type: str | None = None
    product_version: str | None = None
    device_class: str | None = None
    model_number: str | None = None


_DEVICE_CLASS_PRIORITY = {"ipad": 0, "iphone": 1, "ipod": 2}


def _device_priority(dev: DeviceInfo) -> int:
    """Lower = better. iPad wins over iPhone wins over anything else."""
    dc = (dev.device_class or "").lower()
    return _DEVICE_CLASS_PRIORITY.get(dc, 3)


def pick_device(
    devices: list[DeviceInfo],
    prefer_udid: str | None = None,
) -> DeviceInfo | None:
    """Select the best device from a list.

    If `prefer_udid` is given, returns that device if attached, otherwise None
    (strict: the caller asked for a specific device and it's not here).
    Otherwise: iPad → iPhone → iPod → anything. Returns None for empty list.
    """
    if not devices:
        return None
    if prefer_udid:
        for d in devices:
            if d.udid == prefer_udid:
                return d
        return None
    return min(devices, key=_device_priority)


def discover_device(timeout: float = 5.0) -> DeviceInfo:
    """Find the first connected iOS device.

    Raises DeviceNotFoundError if no device is found within timeout.
    """
    md = get_md()
    cf = get_cf()
    k = get_cf_constants()

    found_device = [None]
    found_udid = [None]

    @AMDeviceNotificationCallback
    def _callback(info_ptr, _user_data):
        device = cast(info_ptr, POINTER(c_void_p))[0]
        if device and not found_device[0]:
            md.AMDeviceRetain(device)
            found_device[0] = device
            found_udid[0] = cfstr_to_str(md.AMDeviceCopyDeviceIdentifier(device))

    notification = c_void_p()
    md.AMDeviceNotificationSubscribe(_callback, 0, 0, None, byref(notification))

    iterations = int(timeout / 0.1)
    for _ in range(iterations):
        cf.CFRunLoopRunInMode(k.kCFRunLoopDefaultMode, 0.1, False)
        if found_device[0]:
            break

    if not found_device[0]:
        raise DeviceNotFoundError(
            "No iOS device found. Is your device connected and trusted?"
        )

    return DeviceInfo(udid=found_udid[0], handle=found_device[0])


def list_devices(timeout: float = 5.0, with_details: bool = False) -> list[DeviceInfo]:
    """Find all connected iOS devices.

    If with_details is True, each device is opened with a short lockdown
    session to fill in DeviceName/ProductType/ProductVersion. This takes a
    fraction of a second per device.
    """
    md = get_md()
    cf = get_cf()
    k = get_cf_constants()

    devices: list[DeviceInfo] = []
    seen_udids: set[str] = set()

    @AMDeviceNotificationCallback
    def _callback(info_ptr, _user_data):
        device = cast(info_ptr, POINTER(c_void_p))[0]
        if device:
            udid = cfstr_to_str(md.AMDeviceCopyDeviceIdentifier(device))
            if udid and udid not in seen_udids:
                md.AMDeviceRetain(device)
                seen_udids.add(udid)
                devices.append(DeviceInfo(udid=udid, handle=device))

    notification = c_void_p()
    md.AMDeviceNotificationSubscribe(_callback, 0, 0, None, byref(notification))

    iterations = int(timeout / 0.1)
    for _ in range(iterations):
        cf.CFRunLoopRunInMode(k.kCFRunLoopDefaultMode, 0.1, False)

    if with_details:
        for d in devices:
            try:
                query_device_details(d)
            except Exception:
                pass  # best-effort — leave fields as None

    return devices


def query_device_details(device: DeviceInfo) -> DeviceInfo:
    """Open a short lockdown session and fill device metadata fields in place.

    Uses AMDeviceCopyValue against the default lockdown domain. Closes the
    session and disconnects before returning. Mutates and returns `device`.
    """
    md = get_md()

    if md.AMDeviceConnect(device.handle) != 0:
        return device
    try:
        if md.AMDeviceStartSession(device.handle) != 0:
            return device
        try:
            def _q(key: str) -> str | None:
                ref = md.AMDeviceCopyValue(device.handle, None, cfstr(key))
                return cfstr_to_str(ref) if ref else None

            device.name = _q("DeviceName")
            device.product_type = _q("ProductType")
            device.product_version = _q("ProductVersion")
            device.device_class = _q("DeviceClass")
            device.model_number = _q("ModelNumber")
        finally:
            md.AMDeviceStopSession(device.handle)
    finally:
        md.AMDeviceDisconnect(device.handle)

    return device


def query_device_disk_space(device: DeviceInfo) -> tuple[int, int] | None:
    """Query (free_bytes, total_bytes) from the device.

    Uses the lockdown `com.apple.disk_usage` domain. Returns None if the
    query fails (connection, session, or missing values).
    """
    md = get_md()

    if md.AMDeviceConnect(device.handle) != 0:
        return None
    try:
        if md.AMDeviceStartSession(device.handle) != 0:
            return None
        try:
            domain = cfstr("com.apple.disk_usage")
            total_ref = md.AMDeviceCopyValue(device.handle, domain, cfstr("TotalDiskCapacity"))
            free_ref = md.AMDeviceCopyValue(device.handle, domain, cfstr("AmountDataAvailable"))
            total = cfnumber_to_int(total_ref)
            free = cfnumber_to_int(free_ref)
            if total is None or free is None:
                return None
            return (free, total)
        finally:
            md.AMDeviceStopSession(device.handle)
    finally:
        md.AMDeviceDisconnect(device.handle)
