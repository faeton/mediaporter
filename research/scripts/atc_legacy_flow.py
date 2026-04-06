#!/usr/bin/env python3
"""
PoC: Replicate third-party tool's exact ATC sync flow (from LLDB trace).

Flow:
1. AMDeviceSecureStartService("com.apple.afc")  — via ATHostConnection internally
2. ATHostConnectionSendHostInfo (minimal: LibraryID, SyncHostName, Version)
3. Read device responses (InstalledAssets, AssetMetrics, SyncAllowed, etc.)
4. ATHostConnectionSendMetadataSyncFinished({Keybag=1, Media=1}, {Media=7})
5. ATHostConnectionSendFileBegin(AssetID, Dataclass, FileSize)
6. ATHostConnectionSendFileProgress (repeated)
7. ATHostConnectionSendAssetCompleted(AssetID, Dataclass, AssetPath)

Key differences from our failing PoCs:
- NO SendSyncRequest / BeginSync (these trigger Grappa check → ErrorCode 12)
- HostInfo is minimal (no HostID, no HostName, just LibraryID/SyncHostName/Version)
- MetadataSyncFinished BEFORE FileBegin
"""
import ctypes
from ctypes import c_void_p, c_char_p, c_int, c_uint, c_int64, CFUNCTYPE, POINTER, byref, cast
import signal
import sys
import os
import random
import struct

TEST_FILE = sys.argv[1] if len(sys.argv) > 1 else None


def p(msg):
    print(msg, flush=True)


def timeout_handler(signum, frame):
    raise TimeoutError()


signal.signal(signal.SIGALRM, timeout_handler)

# ── Load frameworks ──────────────────────────────────────────────────────
CF = ctypes.cdll.LoadLibrary(
    "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
)
MD = ctypes.cdll.LoadLibrary(
    "/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice"
)
ATH = ctypes.cdll.LoadLibrary(
    "/System/Library/PrivateFrameworks/AirTrafficHost.framework/AirTrafficHost"
)

kCFAllocatorDefault = c_void_p.in_dll(CF, "kCFAllocatorDefault")
kCFBooleanTrue = c_void_p.in_dll(CF, "kCFBooleanTrue")
kCFBooleanFalse = c_void_p.in_dll(CF, "kCFBooleanFalse")
kCFTypeDictionaryKeyCallBacks = c_void_p.in_dll(CF, "kCFTypeDictionaryKeyCallBacks")
kCFTypeDictionaryValueCallBacks = c_void_p.in_dll(
    CF, "kCFTypeDictionaryValueCallBacks"
)
kCFTypeArrayCallBacks = c_void_p.in_dll(CF, "kCFTypeArrayCallBacks")
kCFRunLoopDefaultMode = c_void_p.in_dll(CF, "kCFRunLoopDefaultMode")

CF.CFStringCreateWithCString.restype = c_void_p
CF.CFStringCreateWithCString.argtypes = [c_void_p, c_char_p, c_uint]
CF.CFStringGetCString.restype = ctypes.c_bool
CF.CFStringGetCString.argtypes = [c_void_p, c_char_p, c_int, c_uint]
CF.CFNumberCreate.restype = c_void_p
CF.CFNumberCreate.argtypes = [c_void_p, c_int, c_void_p]
CF.CFDictionaryCreateMutable.restype = c_void_p
CF.CFDictionaryCreateMutable.argtypes = [c_void_p, c_int, c_void_p, c_void_p]
CF.CFDictionarySetValue.restype = None
CF.CFDictionarySetValue.argtypes = [c_void_p, c_void_p, c_void_p]
CF.CFArrayCreateMutable.restype = c_void_p
CF.CFArrayCreateMutable.argtypes = [c_void_p, c_int, c_void_p]
CF.CFArrayAppendValue.restype = None
CF.CFArrayAppendValue.argtypes = [c_void_p, c_void_p]
CF.CFRunLoopRunInMode.restype = c_int
CF.CFRunLoopRunInMode.argtypes = [c_void_p, ctypes.c_double, ctypes.c_bool]
CF.CFShow.restype = None
CF.CFShow.argtypes = [c_void_p]
CF.CFArrayGetCount.restype = c_int
CF.CFArrayGetCount.argtypes = [c_void_p]
CF.CFArrayGetValueAtIndex.restype = c_void_p
CF.CFArrayGetValueAtIndex.argtypes = [c_void_p, c_int]

AMDeviceNotificationCallback = CFUNCTYPE(None, c_void_p, c_void_p)

MD.AMDeviceNotificationSubscribe.restype = c_int
MD.AMDeviceNotificationSubscribe.argtypes = [
    AMDeviceNotificationCallback, c_uint, c_uint, c_void_p, POINTER(c_void_p),
]
MD.AMDeviceCopyDeviceIdentifier.restype = c_void_p
MD.AMDeviceCopyDeviceIdentifier.argtypes = [c_void_p]
MD.AMDeviceRetain.restype = c_void_p
MD.AMDeviceRetain.argtypes = [c_void_p]

# ATHostConnection
ATH.ATHostConnectionCreateWithLibrary.restype = c_void_p
ATH.ATHostConnectionCreateWithLibrary.argtypes = [c_void_p, c_void_p, c_uint]
ATH.ATHostConnectionGetGrappaSessionId.restype = c_uint
ATH.ATHostConnectionGetGrappaSessionId.argtypes = [c_void_p]
ATH.ATHostConnectionGetCurrentSessionNumber.restype = c_uint
ATH.ATHostConnectionGetCurrentSessionNumber.argtypes = [c_void_p]
ATH.ATHostConnectionSendHostInfo.restype = c_void_p  # may return message ptr, not error code
ATH.ATHostConnectionSendHostInfo.argtypes = [c_void_p, c_void_p]
ATH.ATHostConnectionReadMessage.restype = c_void_p
ATH.ATHostConnectionReadMessage.argtypes = [c_void_p]
ATH.ATHostConnectionSendMetadataSyncFinished.restype = c_int
ATH.ATHostConnectionSendMetadataSyncFinished.argtypes = [c_void_p, c_void_p, c_void_p]
ATH.ATHostConnectionSendFileBegin.restype = c_int
ATH.ATHostConnectionSendFileBegin.argtypes = [c_void_p, c_void_p]
ATH.ATHostConnectionSendFileProgress.restype = c_int
ATH.ATHostConnectionSendFileProgress.argtypes = [c_void_p, c_void_p, c_void_p]
ATH.ATHostConnectionSendAssetCompleted.restype = c_int
ATH.ATHostConnectionSendAssetCompleted.argtypes = [
    c_void_p, c_void_p, c_void_p, c_void_p,
]
ATH.ATHostConnectionSendMessage.restype = c_int
ATH.ATHostConnectionSendMessage.argtypes = [c_void_p, c_void_p]
ATH.ATHostConnectionInvalidate.restype = c_int
ATH.ATHostConnectionInvalidate.argtypes = [c_void_p]
ATH.ATHostConnectionRelease.restype = None
ATH.ATHostConnectionRelease.argtypes = [c_void_p]

# ATCFMessage
ATH.ATCFMessageGetName.restype = c_void_p
ATH.ATCFMessageGetName.argtypes = [c_void_p]
ATH.ATCFMessageGetParam.restype = c_void_p
ATH.ATCFMessageGetParam.argtypes = [c_void_p, c_void_p]
ATH.ATCFMessageGetSessionNumber.restype = c_uint
ATH.ATCFMessageGetSessionNumber.argtypes = [c_void_p]
ATH.ATCFMessageCreate.restype = c_void_p
ATH.ATCFMessageCreate.argtypes = [c_uint, c_void_p, c_void_p]


def cfstr(s):
    return CF.CFStringCreateWithCString(kCFAllocatorDefault, s.encode("utf-8"), 0x08000100)


def cfstr_to_str(cf):
    if not cf:
        return None
    buf = ctypes.create_string_buffer(4096)
    return buf.value.decode("utf-8") if CF.CFStringGetCString(cf, buf, 4096, 0x08000100) else None


def cfnum_int64(val):
    v = ctypes.c_int64(val)
    return CF.CFNumberCreate(kCFAllocatorDefault, 4, byref(v))  # 4 = kCFNumberSInt64Type


def cfnum_int32(val):
    v = ctypes.c_int32(val)
    return CF.CFNumberCreate(kCFAllocatorDefault, 3, byref(v))  # 3 = kCFNumberSInt32Type


def cfdict(**kwargs):
    d = CF.CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0, kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks
    )
    for k, v in kwargs.items():
        CF.CFDictionarySetValue(d, cfstr(k), v)
    return d


def read_msg(conn, timeout_sec=8):
    signal.alarm(timeout_sec)
    try:
        msg = ATH.ATHostConnectionReadMessage(conn)
        signal.alarm(0)
        if not msg:
            return None, None
        name = cfstr_to_str(ATH.ATCFMessageGetName(msg))
        return msg, name
    except TimeoutError:
        signal.alarm(0)
        return None, "TIMEOUT"


# ── Find device via notification (like third-party tool) ───────────────────────────
p("[*] Waiting for device...")
found_device = [None]
found_udid = [None]


@AMDeviceNotificationCallback
def device_callback(info_ptr, user_data):
    device = cast(info_ptr, POINTER(c_void_p))[0]
    if device and not found_device[0]:
        MD.AMDeviceRetain(device)
        udid_cf = MD.AMDeviceCopyDeviceIdentifier(device)
        udid = cfstr_to_str(udid_cf)
        p(f"[+] Device: {udid}")
        found_device[0] = device
        found_udid[0] = udid


notification = c_void_p()
err = MD.AMDeviceNotificationSubscribe(device_callback, 0, 0, None, byref(notification))
if err != 0:
    p(f"[-] NotificationSubscribe failed: {err}")
    sys.exit(1)

for _ in range(50):
    CF.CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, False)
    if found_device[0]:
        break

if not found_device[0]:
    p("[-] No device found")
    sys.exit(1)

udid = found_udid[0]

# ── Create ATHostConnection (NO prior AMDeviceConnect/StartSession) ─────
p("\n[*] Creating ATHostConnection...")
conn = ATH.ATHostConnectionCreateWithLibrary(cfstr("com.mediaporter.sync"), cfstr(udid), 0)
if not conn:
    p("[-] ATHostConnectionCreateWithLibrary returned NULL")
    sys.exit(1)
p(f"[+] conn={hex(conn)}")

# ── Step 1: Send HostInfo (matching third-party tool's minimal format) ─────────────
p("\n[*] Step 1: SendHostInfo (third-party tool-style minimal)")
host_info = cfdict(
    LibraryID=cfstr("MEDIAPORTER00001"),
    SyncHostName=cfstr(os.uname().nodename.split(".")[0]),
    SyncedDataclasses=CF.CFArrayCreateMutable(kCFAllocatorDefault, 0, kCFTypeArrayCallBacks),
    Version=cfstr("12.8"),
)
ret = ATH.ATHostConnectionSendHostInfo(conn, host_info)
p(f"    SendHostInfo result: {hex(ret) if ret else 'NULL'}")

# ── Step 2: Read all device responses ───────────────────────────────────
p("\n[*] Step 2: Reading device responses...")
device_msgs = []
for i in range(15):
    msg, name = read_msg(conn, timeout_sec=5)
    if name == "TIMEOUT":
        p(f"    [{i}] TIMEOUT — done reading")
        break
    if name is None:
        p(f"    [{i}] NULL — done reading")
        break
    session = ATH.ATCFMessageGetSessionNumber(msg)
    grappa = ATH.ATHostConnectionGetGrappaSessionId(conn)
    p(f"    [{i}] << {name} (session={session}, grappa={grappa})")
    device_msgs.append(name)

    # Show some params for key messages
    if name == "SyncAllowed":
        for param_name in ["ManualSync", "AutoSync", "PurgeAllowed"]:
            val = ATH.ATCFMessageGetParam(msg, cfstr(param_name))
            if val:
                p(f"        {param_name}: {hex(val)}")

    if name == "SyncFailed":
        p("        [dumping SyncFailed message]")
        CF.CFShow(msg)

p(f"\n    Messages received: {device_msgs}")

if not TEST_FILE:
    p("\n[!] No test file specified. Pass a file path as argument to transfer.")
    p("    Usage: python3 scripts/atc_legacy_flow.py /path/to/video.mp4")
    ATH.ATHostConnectionInvalidate(conn)
    ATH.ATHostConnectionRelease(conn)
    sys.exit(0)

if not os.path.exists(TEST_FILE):
    p(f"[-] File not found: {TEST_FILE}")
    ATH.ATHostConnectionInvalidate(conn)
    ATH.ATHostConnectionRelease(conn)
    sys.exit(1)

file_size = os.path.getsize(TEST_FILE)
p(f"\n[*] File: {TEST_FILE} ({file_size} bytes)")

# ── Step 3: SendMetadataSyncFinished ────────────────────────────────────
p("\n[*] Step 3: SendMetadataSyncFinished")
sync_types = cfdict(
    Keybag=cfnum_int32(1),
    Media=cfnum_int32(1),
)
dataclass_anchors = cfdict(
    Media=cfnum_int32(7),
)
err = ATH.ATHostConnectionSendMetadataSyncFinished(conn, sync_types, dataclass_anchors)
p(f"    SendMetadataSyncFinished result: {err} (0x{err & 0xFFFFFFFF:08x})")

# Read response
for i in range(5):
    msg, name = read_msg(conn, timeout_sec=3)
    if name in ["TIMEOUT", None]:
        p(f"    Response [{i}]: {name or 'NULL'}")
        break
    p(f"    Response [{i}]: << {name}")
    if name == "SyncFailed":
        p("        [dumping SyncFailed message]")
        CF.CFShow(msg)
        p("\n[!] SyncFailed — trying manual ATCFMessage approach instead...")
        break

# ── Step 4: Try manual FileBegin via ATCFMessage ───────────────────────
p("\n[*] Step 4: SendFileBegin via manual ATCFMessage")
asset_id = random.randint(100000000000000000, 999999999999999999)
p(f"    AssetID: {asset_id}")

file_begin_params = cfdict(
    AssetID=cfnum_int64(asset_id),
    Dataclass=cfstr("Media"),
    FileSize=cfnum_int64(file_size),
    TotalSize=cfnum_int64(file_size),
)
file_begin_msg = ATH.ATCFMessageCreate(0, cfstr("FileBegin"), file_begin_params)
if file_begin_msg:
    p(f"    Created FileBegin message: {hex(file_begin_msg)}")
    err = ATH.ATHostConnectionSendMessage(conn, file_begin_msg)
    p(f"    SendMessage(FileBegin) result: {err} (0x{err & 0xFFFFFFFF:08x})")
else:
    p("    Failed to create FileBegin message")

# Read response
for i in range(3):
    msg, name = read_msg(conn, timeout_sec=3)
    if name in ["TIMEOUT", None]:
        p(f"    Response [{i}]: {name or 'NULL'}")
        break
    p(f"    Response [{i}]: << {name}")

p(f"\n[*] Got to FileBegin stage — this is further than any previous PoC!")

# ── Cleanup ─────────────────────────────────────────────────────────────
ATH.ATHostConnectionInvalidate(conn)
ATH.ATHostConnectionRelease(conn)
p("\n[+] Done")
