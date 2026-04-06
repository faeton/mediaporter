"""iOS device detection and communication via pymobiledevice3.

All operations use a single persistent event loop to avoid async context issues.
For iOS 17+, start the tunnel service first:
    sudo pymobiledevice3 remote start-tunnel
"""

from __future__ import annotations

import asyncio
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from mediaporter.exceptions import DeviceError, DeviceNotFoundError, DeviceNotPairedError


@dataclass
class DeviceInfo:
    """Basic information about a connected iOS device."""
    udid: str
    name: str
    model: str
    ios_version: str
    device_class: str


# Persistent event loop running in a background thread
_loop: asyncio.AbstractEventLoop | None = None
_thread: threading.Thread | None = None


def _get_loop() -> asyncio.AbstractEventLoop:
    """Get or create a persistent event loop in a background thread."""
    global _loop, _thread
    if _loop is None or _loop.is_closed():
        _loop = asyncio.new_event_loop()
        _thread = threading.Thread(target=_loop.run_forever, daemon=True)
        _thread.start()
    return _loop


def _run(coro):
    """Run an async coroutine on the persistent event loop."""
    loop = _get_loop()
    future = asyncio.run_coroutine_threadsafe(coro, loop)
    return future.result(timeout=30)


def list_devices() -> list[DeviceInfo]:
    """List all connected iOS devices."""
    try:
        from pymobiledevice3.usbmux import list_devices as usbmux_list
    except ImportError:
        raise DeviceError("pymobiledevice3 not installed. Run: pip install pymobiledevice3")

    devices = []

    # Try usbmux (iOS < 17)
    usb_devices = _run(usbmux_list())
    for usb_device in usb_devices:
        try:
            lockdown = _create_lockdown_usbmux(usb_device.serial)
            all_values = lockdown.all_values
            devices.append(DeviceInfo(
                udid=usb_device.serial,
                name=all_values.get("DeviceName", "Unknown"),
                model=all_values.get("ProductType", "Unknown"),
                ios_version=all_values.get("ProductVersion", "Unknown"),
                device_class=all_values.get("DeviceClass", "Unknown"),
            ))
        except Exception:
            devices.append(DeviceInfo(
                udid=usb_device.serial,
                name="(not paired)",
                model="Unknown",
                ios_version="Unknown",
                device_class="Unknown",
            ))

    # Try tunnel-based discovery (iOS 17+)
    if not devices:
        try:
            tunnel_devices = _list_tunnel_devices()
            devices.extend(tunnel_devices)
        except Exception:
            pass

    return devices


def _create_lockdown_usbmux(serial: str):
    from pymobiledevice3.lockdown import create_using_usbmux
    return _run(create_using_usbmux(serial=serial))


def _list_tunnel_devices() -> list[DeviceInfo]:
    try:
        from pymobiledevice3.remote.tunnel_service import get_tunneld_devices
    except ImportError:
        return []

    devices = []
    try:
        tunneld_devices = _run(get_tunneld_devices())
        for rsd in tunneld_devices:
            try:
                all_values = rsd.peer_info
                devices.append(DeviceInfo(
                    udid=all_values.get("UniqueDeviceID", "unknown"),
                    name=all_values.get("DeviceName", "Unknown"),
                    model=all_values.get("ProductType", "Unknown"),
                    ios_version=all_values.get("ProductVersion", "Unknown"),
                    device_class=all_values.get("DeviceClass", "Unknown"),
                ))
            except Exception:
                pass
    except Exception:
        pass

    return devices


def get_device(udid: str | None = None):
    """Get a connected device's lockdown client."""
    try:
        from pymobiledevice3.usbmux import list_devices as usbmux_list
    except ImportError:
        raise DeviceError("pymobiledevice3 not installed.")

    # Try usbmux first
    usb_devices = _run(usbmux_list())
    if usb_devices:
        serial = udid or usb_devices[0].serial
        if udid and not any(d.serial == udid for d in usb_devices):
            raise DeviceNotFoundError(f"Device {udid} not found.")
        try:
            return _create_lockdown_usbmux(serial)
        except Exception as e:
            raise DeviceNotPairedError(f"Cannot connect: {e}")

    # Try tunnel (iOS 17+)
    try:
        from pymobiledevice3.remote.tunnel_service import get_tunneld_devices
        from pymobiledevice3.lockdown import create_using_remote

        tunneld_devices = _run(get_tunneld_devices())
        if tunneld_devices:
            rsd = tunneld_devices[0]
            return _run(create_using_remote(rsd))
    except Exception:
        pass

    raise DeviceNotFoundError(
        "No iOS device found. Make sure your device is:\n"
        "  1. Connected via USB-C\n"
        "  2. Unlocked\n"
        "  3. Trusted (tap 'Trust' on the device)\n\n"
        "For iOS 17+, also start the tunnel service:\n"
        "  sudo pymobiledevice3 remote start-tunnel"
    )


def afc_list_dir(lockdown, path: str) -> list[str]:
    """List directory contents on device via AFC."""
    from pymobiledevice3.services.afc import AfcService

    async def _op():
        async with AfcService(lockdown=lockdown) as afc:
            return await afc.listdir(path)

    return _run(_op())


def afc_push_file(
    lockdown,
    local_path: Path,
    remote_path: str,
    progress_callback: Callable[[int, int], None] | None = None,
) -> None:
    """Push a file to device via AFC."""
    from pymobiledevice3.services.afc import AfcService

    file_size = local_path.stat().st_size

    async def _op():
        async with AfcService(lockdown=lockdown) as afc:
            await afc.push(str(local_path), remote_path)

    _run(_op())

    if progress_callback:
        progress_callback(file_size, file_size)


def afc_pull_file(lockdown, remote_path: str, local_path: Path) -> None:
    """Pull a file from device via AFC."""
    from pymobiledevice3.services.afc import AfcService

    async def _op():
        async with AfcService(lockdown=lockdown) as afc:
            await afc.pull(remote_path, str(local_path))

    _run(_op())


def afc_mkdir(lockdown, remote_path: str) -> None:
    """Create a directory on device via AFC."""
    from pymobiledevice3.services.afc import AfcService

    async def _op():
        async with AfcService(lockdown=lockdown) as afc:
            await afc.makedirs(remote_path)

    _run(_op())
