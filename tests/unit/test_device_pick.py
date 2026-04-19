"""Multi-device selection: prefer iPad, honor explicit UDID."""

from ctypes import c_void_p

from mediaporter.sync.device import DeviceInfo, pick_device


def _dev(udid: str, device_class: str | None, name: str | None = None) -> DeviceInfo:
    return DeviceInfo(
        udid=udid,
        handle=c_void_p(0),
        name=name,
        device_class=device_class,
    )


def test_pick_empty_returns_none():
    assert pick_device([]) is None


def test_pick_single_device_returns_it():
    d = _dev("abc", "iPad")
    assert pick_device([d]) is d


def test_pick_prefers_ipad_over_iphone():
    phone = _dev("phone-udid", "iPhone", name="Work iPhone")
    pad = _dev("ipad-udid", "iPad", name="Home iPad")
    # Order shouldn't matter — iPad wins regardless.
    assert pick_device([phone, pad]) is pad
    assert pick_device([pad, phone]) is pad


def test_pick_prefers_iphone_over_ipod():
    phone = _dev("p", "iPhone")
    pod = _dev("i", "iPod")
    assert pick_device([pod, phone]) is phone


def test_pick_falls_back_to_unknown_class():
    # Unknown device class still selectable if it's all we have.
    unknown = _dev("u", None)
    assert pick_device([unknown]) is unknown


def test_pick_prefer_udid_beats_device_class():
    # Explicit UDID wins even over the iPad-preference rule.
    phone = _dev("phone-udid", "iPhone")
    pad = _dev("ipad-udid", "iPad")
    assert pick_device([phone, pad], prefer_udid="phone-udid") is phone


def test_pick_prefer_udid_strict_when_not_connected():
    # Asking for a UDID that isn't attached returns None (strict) so the
    # pipeline can emit "Requested device X is not connected" rather than
    # silently syncing to the wrong device.
    pad = _dev("ipad-udid", "iPad")
    assert pick_device([pad], prefer_udid="not-connected") is None
