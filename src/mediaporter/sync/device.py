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
    cfstr_to_str,
    get_cf,
    get_cf_constants,
    get_md,
)


@dataclass
class DeviceInfo:
    """Connected iOS device."""
    udid: str
    handle: c_void_p


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


def list_devices(timeout: float = 5.0) -> list[DeviceInfo]:
    """Find all connected iOS devices."""
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

    return devices
