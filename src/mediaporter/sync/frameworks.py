"""Apple private framework loading via ctypes.

Lazy-loads CoreFoundation, MobileDevice, AirTrafficHost, and libcig.dylib.
All function signatures match the patterns proven in scripts/atc_nodeps_sync.py.
"""

from __future__ import annotations

import ctypes
from ctypes import (
    CFUNCTYPE,
    POINTER,
    byref,
    c_char_p,
    c_int,
    c_long,
    c_uint,
    c_void_p,
)
from importlib.resources import files

# ---------------------------------------------------------------------------
# Lazy framework handles
# ---------------------------------------------------------------------------
_CF = None
_MD = None
_ATH = None
_CIG = None
_CF_CONSTANTS = None
_GRAPPA_BYTES = None


def get_cf():
    """Load CoreFoundation.framework."""
    global _CF
    if _CF is None:
        _CF = ctypes.cdll.LoadLibrary(
            "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
        )
        _setup_cf(_CF)
    return _CF


def get_md():
    """Load MobileDevice.framework."""
    global _MD
    if _MD is None:
        _MD = ctypes.cdll.LoadLibrary(
            "/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice"
        )
        _setup_md(_MD)
    return _MD


def get_ath():
    """Load AirTrafficHost.framework."""
    global _ATH
    if _ATH is None:
        _ATH = ctypes.cdll.LoadLibrary(
            "/System/Library/PrivateFrameworks/AirTrafficHost.framework/AirTrafficHost"
        )
        _setup_ath(_ATH)
    return _ATH


def get_cig():
    """Load libcig.dylib from package data."""
    global _CIG
    if _CIG is None:
        data_dir = files("mediaporter.sync") / "data"
        lib_path = str(data_dir / "libcig.dylib")
        _CIG = ctypes.cdll.LoadLibrary(lib_path)
        _CIG.cig_calc.restype = c_int
        _CIG.cig_calc.argtypes = [c_char_p, c_char_p, c_int, c_char_p, POINTER(c_int)]
    return _CIG


def get_grappa_bytes() -> bytes:
    """Load the 84-byte static Grappa blob from package data."""
    global _GRAPPA_BYTES
    if _GRAPPA_BYTES is None:
        data_dir = files("mediaporter.sync") / "data"
        _GRAPPA_BYTES = (data_dir / "grappa.bin").read_bytes()
    return _GRAPPA_BYTES


# ---------------------------------------------------------------------------
# CF constants — resolved lazily from framework symbols
# ---------------------------------------------------------------------------
class _CFConstants:
    def __init__(self, cf):
        self.kCFAllocatorDefault = c_void_p.in_dll(cf, "kCFAllocatorDefault")
        self.kCFTypeDictionaryKeyCallBacks = c_void_p.in_dll(cf, "kCFTypeDictionaryKeyCallBacks")
        self.kCFTypeDictionaryValueCallBacks = c_void_p.in_dll(
            cf, "kCFTypeDictionaryValueCallBacks"
        )
        self.kCFTypeArrayCallBacks = c_void_p.in_dll(cf, "kCFTypeArrayCallBacks")
        self.kCFRunLoopDefaultMode = c_void_p.in_dll(cf, "kCFRunLoopDefaultMode")
        self.kCFBooleanTrue = c_void_p.in_dll(cf, "kCFBooleanTrue")


def get_cf_constants() -> _CFConstants:
    global _CF_CONSTANTS
    if _CF_CONSTANTS is None:
        _CF_CONSTANTS = _CFConstants(get_cf())
    return _CF_CONSTANTS


# ---------------------------------------------------------------------------
# CF helper functions
# ---------------------------------------------------------------------------
def cfstr(s: str) -> c_void_p:
    """Create a CFString from a Python string."""
    cf = get_cf()
    k = get_cf_constants()
    return cf.CFStringCreateWithCString(k.kCFAllocatorDefault, s.encode("utf-8"), 0x08000100)


def cfstr_to_str(cf_ref: c_void_p) -> str | None:
    """Convert a CFString to a Python string."""
    if not cf_ref:
        return None
    cf = get_cf()
    buf = ctypes.create_string_buffer(4096)
    if cf.CFStringGetCString(cf_ref, buf, 4096, 0x08000100):
        return buf.value.decode("utf-8")
    return None


def cfnum32(v: int) -> c_void_p:
    """Create a CFNumber (32-bit int)."""
    cf = get_cf()
    k = get_cf_constants()
    val = ctypes.c_int32(v)
    return cf.CFNumberCreate(k.kCFAllocatorDefault, 3, byref(val))


def cfnum64(v: int) -> c_void_p:
    """Create a CFNumber (64-bit int)."""
    cf = get_cf()
    k = get_cf_constants()
    val = ctypes.c_int64(v)
    return cf.CFNumberCreate(k.kCFAllocatorDefault, 4, byref(val))


def cfdouble(v: float) -> c_void_p:
    """Create a CFNumber (double)."""
    cf = get_cf()
    k = get_cf_constants()
    val = ctypes.c_double(v)
    return cf.CFNumberCreate(k.kCFAllocatorDefault, 13, byref(val))


def cfdict(**kwargs) -> c_void_p:
    """Create a CFMutableDictionary from keyword arguments."""
    cf = get_cf()
    k = get_cf_constants()
    d = cf.CFDictionaryCreateMutable(
        k.kCFAllocatorDefault, 0,
        k.kCFTypeDictionaryKeyCallBacks,
        k.kCFTypeDictionaryValueCallBacks,
    )
    for key, val in kwargs.items():
        cf.CFDictionarySetValue(d, cfstr(key), val)
    return d


def cfarray(*items) -> c_void_p:
    """Create a CFMutableArray from items."""
    cf = get_cf()
    k = get_cf_constants()
    arr = cf.CFArrayCreateMutable(k.kCFAllocatorDefault, 0, k.kCFTypeArrayCallBacks)
    for item in items:
        cf.CFArrayAppendValue(arr, item)
    return arr


def cfdata(data: bytes) -> c_void_p:
    """Create a CFData from bytes."""
    cf = get_cf()
    k = get_cf_constants()
    return cf.CFDataCreate(k.kCFAllocatorDefault, data, len(data))


# ---------------------------------------------------------------------------
# Callback type for device notifications
# ---------------------------------------------------------------------------
AMDeviceNotificationCallback = CFUNCTYPE(None, c_void_p, c_void_p)


# ---------------------------------------------------------------------------
# Framework function setup
# ---------------------------------------------------------------------------
def _setup_cf(cf):
    """Configure CoreFoundation function signatures."""
    for fn, rt, at in [
        ("CFStringCreateWithCString", c_void_p, [c_void_p, c_char_p, c_uint]),
        ("CFStringGetCString", ctypes.c_bool, [c_void_p, c_char_p, c_int, c_uint]),
        ("CFDictionaryCreateMutable", c_void_p, [c_void_p, c_int, c_void_p, c_void_p]),
        ("CFDictionarySetValue", None, [c_void_p, c_void_p, c_void_p]),
        ("CFDictionaryGetValue", c_void_p, [c_void_p, c_void_p]),
        ("CFArrayCreateMutable", c_void_p, [c_void_p, c_int, c_void_p]),
        ("CFArrayAppendValue", None, [c_void_p, c_void_p]),
        ("CFRunLoopRunInMode", c_int, [c_void_p, ctypes.c_double, ctypes.c_bool]),
        ("CFShow", None, [c_void_p]),
        ("CFNumberCreate", c_void_p, [c_void_p, c_int, c_void_p]),
        ("CFDataCreate", c_void_p, [c_void_p, c_char_p, c_long]),
        ("CFDataGetBytePtr", ctypes.POINTER(ctypes.c_ubyte), [c_void_p]),
        ("CFDataGetLength", c_long, [c_void_p]),
        ("CFGetTypeID", c_long, [c_void_p]),
        ("CFDictionaryGetTypeID", c_long, []),
        ("CFDataGetTypeID", c_long, []),
        ("CFStringGetTypeID", c_long, []),
    ]:
        getattr(cf, fn).restype = rt
        if at:
            getattr(cf, fn).argtypes = at


def _setup_md(md):
    """Configure MobileDevice function signatures."""
    for fn, rt, at in [
        ("AMDeviceNotificationSubscribe", c_int,
         [AMDeviceNotificationCallback, c_uint, c_uint, c_void_p, POINTER(c_void_p)]),
        ("AMDeviceCopyDeviceIdentifier", c_void_p, [c_void_p]),
        ("AMDeviceRetain", c_void_p, [c_void_p]),
        ("AMDeviceConnect", c_int, [c_void_p]),
        ("AMDeviceStartSession", c_int, [c_void_p]),
        ("AMDeviceStartService", c_int, [c_void_p, c_void_p, POINTER(c_void_p), c_void_p]),
        ("AMDeviceDisconnect", c_int, [c_void_p]),
        ("AFCConnectionOpen", c_int, [c_void_p, c_uint, POINTER(c_void_p)]),
        ("AFCConnectionClose", c_int, [c_void_p]),
        ("AFCDirectoryCreate", c_int, [c_void_p, c_char_p]),
        ("AFCFileRefOpen", c_int, [c_void_p, c_char_p, c_int, POINTER(c_long)]),
        ("AFCFileRefWrite", c_int, [c_void_p, c_long, c_char_p, c_long]),
        ("AFCFileRefClose", c_int, [c_void_p, c_long]),
        ("AFCRemovePath", c_int, [c_void_p, c_char_p]),
        ("AFCLinkPath", c_int, [c_void_p, c_int, c_char_p, c_char_p]),
    ]:
        getattr(md, fn).restype = rt
        getattr(md, fn).argtypes = at


def _setup_ath(ath):
    """Configure AirTrafficHost function signatures."""
    for fn, rt, at in [
        ("ATHostConnectionCreateWithLibrary", c_void_p, [c_void_p, c_void_p, c_uint]),
        ("ATHostConnectionSendHostInfo", c_void_p, [c_void_p, c_void_p]),
        ("ATHostConnectionReadMessage", c_void_p, [c_void_p]),
        ("ATHostConnectionSendMessage", c_int, [c_void_p, c_void_p]),
        ("ATHostConnectionSendMetadataSyncFinished", c_void_p, [c_void_p, c_void_p, c_void_p]),
        ("ATHostConnectionSendPowerAssertion", c_void_p, [c_void_p, c_void_p]),
        ("ATHostConnectionInvalidate", c_int, [c_void_p]),
        ("ATHostConnectionRelease", None, [c_void_p]),
        ("ATCFMessageGetName", c_void_p, [c_void_p]),
        ("ATCFMessageGetParam", c_void_p, [c_void_p, c_void_p]),
        ("ATCFMessageCreate", c_void_p, [c_uint, c_void_p, c_void_p]),
    ]:
        getattr(ath, fn).restype = rt
        getattr(ath, fn).argtypes = at
