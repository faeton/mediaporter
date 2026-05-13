"""Device integration tests — require connected iPad.

Run with: pytest tests/unit/test_device_sync.py -m ipad
"""

import pytest

pytestmark = pytest.mark.ipad


@pytest.mark.ipad
def test_discover_device():
    from mediaporter.sync.device import discover_device
    device = discover_device(timeout=5.0)
    assert device.udid
    assert len(device.udid) > 10
    assert device.handle is not None


@pytest.mark.ipad
def test_list_devices():
    from mediaporter.sync.device import list_devices
    devices = list_devices(timeout=5.0)
    assert len(devices) >= 1
    assert devices[0].udid


@pytest.mark.ipad
def test_afc_makedirs():
    from mediaporter.sync.afc import NativeAFC
    from mediaporter.sync.device import discover_device

    device = discover_device()
    with NativeAFC(device.handle) as afc:
        # This should not raise
        afc.makedirs("/iTunes_Control/Music/F49")


@pytest.mark.ipad
def test_afc_write_file():
    import random
    import string

    from mediaporter.sync.afc import NativeAFC
    from mediaporter.sync.device import discover_device

    device = discover_device()
    with NativeAFC(device.handle) as afc:
        fname = "".join(random.choices(string.ascii_uppercase, k=4))
        path = f"/iTunes_Control/Music/F49/{fname}.test"
        afc.write_file(path, b"mediaporter test data")
        # Clean up
        afc._md.AFCRemovePath(afc._afc_conn, path.encode("utf-8"))
