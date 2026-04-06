#!/usr/bin/env python3
"""
Full ATC+AFC file sync to iOS device.
Transfers a video file and registers it in the TV app.

Flow:
1. ATC: SendHostInfo → read responses → RequestingSync (with Grappa) → ReadyForSync
2. ATC: SendMetadataSyncFinished
3. ATC: SendFileBegin (tells device a file is coming)
4. AFC: Write file to /iTunes_Control/Music/Fxx/
5. ATC: FileProgress updates
6. ATC: SendAssetCompleted

Usage: python3 scripts/atc_full_sync.py <video.m4v> [grappa.bin]
"""
import asyncio
import ctypes
from ctypes import (
    c_void_p, c_char_p, c_int, c_uint, c_long,
    CFUNCTYPE, POINTER, byref, cast,
)
import signal
import sys
import os
import random
import string

VIDEO_FILE = sys.argv[1] if len(sys.argv) > 1 else None
GRAPPA_FILE = sys.argv[2] if len(sys.argv) > 2 else "/tmp/grappa.bin"

if not VIDEO_FILE or not os.path.exists(VIDEO_FILE):
    print(f"Usage: python3 {sys.argv[0]} <video.m4v> [grappa.bin]")
    sys.exit(1)
if not os.path.exists(GRAPPA_FILE):
    print(f"Grappa blob not found: {GRAPPA_FILE}")
    sys.exit(1)


def p(msg):
    print(msg, flush=True)


def timeout_handler(signum, frame):
    raise TimeoutError()


signal.signal(signal.SIGALRM, timeout_handler)

# ── Load Apple frameworks ────────────────────────────────────────────────
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
kCFTypeDictionaryKeyCallBacks = c_void_p.in_dll(CF, "kCFTypeDictionaryKeyCallBacks")
kCFTypeDictionaryValueCallBacks = c_void_p.in_dll(CF, "kCFTypeDictionaryValueCallBacks")
kCFTypeArrayCallBacks = c_void_p.in_dll(CF, "kCFTypeArrayCallBacks")
kCFRunLoopDefaultMode = c_void_p.in_dll(CF, "kCFRunLoopDefaultMode")

CF.CFStringCreateWithCString.restype = c_void_p
CF.CFStringCreateWithCString.argtypes = [c_void_p, c_char_p, c_uint]
CF.CFStringGetCString.restype = ctypes.c_bool
CF.CFStringGetCString.argtypes = [c_void_p, c_char_p, c_int, c_uint]
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
CF.CFNumberCreate.restype = c_void_p
CF.CFNumberCreate.argtypes = [c_void_p, c_int, c_void_p]
CF.CFDataCreate.restype = c_void_p
CF.CFDataCreate.argtypes = [c_void_p, c_char_p, c_long]

AMDeviceNotificationCallback = CFUNCTYPE(None, c_void_p, c_void_p)
MD.AMDeviceNotificationSubscribe.restype = c_int
MD.AMDeviceNotificationSubscribe.argtypes = [
    AMDeviceNotificationCallback, c_uint, c_uint, c_void_p, POINTER(c_void_p),
]
MD.AMDeviceCopyDeviceIdentifier.restype = c_void_p
MD.AMDeviceCopyDeviceIdentifier.argtypes = [c_void_p]
MD.AMDeviceRetain.restype = c_void_p
MD.AMDeviceRetain.argtypes = [c_void_p]

ATH.ATHostConnectionCreateWithLibrary.restype = c_void_p
ATH.ATHostConnectionCreateWithLibrary.argtypes = [c_void_p, c_void_p, c_uint]
ATH.ATHostConnectionSendHostInfo.restype = c_void_p
ATH.ATHostConnectionSendHostInfo.argtypes = [c_void_p, c_void_p]
ATH.ATHostConnectionReadMessage.restype = c_void_p
ATH.ATHostConnectionReadMessage.argtypes = [c_void_p]
ATH.ATHostConnectionSendMessage.restype = c_int
ATH.ATHostConnectionSendMessage.argtypes = [c_void_p, c_void_p]
ATH.ATHostConnectionSendMetadataSyncFinished.restype = c_int
ATH.ATHostConnectionSendMetadataSyncFinished.argtypes = [c_void_p, c_void_p, c_void_p]
# SendFileBegin: (conn, assetID, dataclass, fileSize, totalSize, fileSize)
ATH.ATHostConnectionSendFileBegin.restype = c_int
ATH.ATHostConnectionSendFileBegin.argtypes = [c_void_p, c_void_p, c_void_p, c_void_p, c_void_p, c_void_p]
# SendAssetCompleted: (conn, assetID, dataclass, assetPath)
ATH.ATHostConnectionSendAssetCompleted.restype = c_int
ATH.ATHostConnectionSendAssetCompleted.argtypes = [c_void_p, c_void_p, c_void_p, c_void_p]
ATH.ATHostConnectionInvalidate.restype = c_int
ATH.ATHostConnectionInvalidate.argtypes = [c_void_p]
ATH.ATHostConnectionRelease.restype = None
ATH.ATHostConnectionRelease.argtypes = [c_void_p]

ATH.ATCFMessageGetName.restype = c_void_p
ATH.ATCFMessageGetName.argtypes = [c_void_p]
ATH.ATCFMessageGetParam.restype = c_void_p
ATH.ATCFMessageGetParam.argtypes = [c_void_p, c_void_p]
ATH.ATCFMessageCreate.restype = c_void_p
ATH.ATCFMessageCreate.argtypes = [c_uint, c_void_p, c_void_p]


def cfstr(s):
    return CF.CFStringCreateWithCString(kCFAllocatorDefault, s.encode("utf-8"), 0x08000100)


def cfstr_to_str(cf):
    if not cf:
        return None
    buf = ctypes.create_string_buffer(4096)
    return buf.value.decode("utf-8") if CF.CFStringGetCString(cf, buf, 4096, 0x08000100) else None


def cfnum32(v):
    val = ctypes.c_int32(v)
    return CF.CFNumberCreate(kCFAllocatorDefault, 3, byref(val))


def cfnum64(v):
    val = ctypes.c_int64(v)
    return CF.CFNumberCreate(kCFAllocatorDefault, 4, byref(val))


def cfdict(**kwargs):
    d = CF.CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0, kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks,
    )
    for k, v in kwargs.items():
        CF.CFDictionarySetValue(d, cfstr(k), v)
    return d


def read_msg(conn, to=8):
    signal.alarm(to)
    try:
        msg = ATH.ATHostConnectionReadMessage(conn)
        signal.alarm(0)
        if not msg:
            return None, None
        return msg, cfstr_to_str(ATH.ATCFMessageGetName(msg))
    except TimeoutError:
        signal.alarm(0)
        return None, "TIMEOUT"


def read_until(conn, target, max_msgs=10, to=5):
    for _ in range(max_msgs):
        msg, name = read_msg(conn, to)
        if name in ["TIMEOUT", None]:
            p(f"    << {name}")
            return None, name
        p(f"    << {name}")
        if name == target:
            return msg, name
        if name == "SyncFailed":
            CF.CFShow(msg)
            return msg, name
    return None, "MAX_MSGS"


def random_filename(ext="mp4"):
    chars = string.ascii_uppercase + string.ascii_lowercase
    name = "".join(random.choices(chars, k=4))
    return f"{name}.{ext}"


# ── Find device ──────────────────────────────────────────────────────────
p("[*] Finding device...")
found = [None, None]


@AMDeviceNotificationCallback
def cb(info_ptr, _):
    d = cast(info_ptr, POINTER(c_void_p))[0]
    if d and not found[0]:
        MD.AMDeviceRetain(d)
        found[0] = d
        found[1] = cfstr_to_str(MD.AMDeviceCopyDeviceIdentifier(d))


n = c_void_p()
MD.AMDeviceNotificationSubscribe(cb, 0, 0, None, byref(n))
for _ in range(50):
    CF.CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, False)
    if found[0]:
        break
if not found[0]:
    p("[-] No device")
    sys.exit(1)

udid = found[1]
p(f"[+] Device: {udid}")

# ── Load Grappa ──────────────────────────────────────────────────────────
with open(GRAPPA_FILE, "rb") as f:
    grappa_bytes = f.read()
p(f"[+] Grappa: {len(grappa_bytes)} bytes")

file_size = os.path.getsize(VIDEO_FILE)
p(f"[+] File: {VIDEO_FILE} ({file_size} bytes)")

# ── Upload file via AFC first ────────────────────────────────────────────
p("\n[1] Uploading file via AFC...")
# Pick a random slot in /iTunes_Control/Music/
slot = f"F{random.randint(0, 49):02d}"
fname = random_filename("mp4")
device_path = f"/iTunes_Control/Music/{slot}/{fname}"


async def upload_via_afc():
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.afc import AfcService

    ld = await create_using_usbmux()
    async with AfcService(ld) as afc:
        # Ensure directory exists
        try:
            await afc.makedirs(f"/iTunes_Control/Music/{slot}")
        except Exception:
            pass
        # Upload file
        with open(VIDEO_FILE, "rb") as local_f:
            data = local_f.read()
        await afc.set_file_contents(device_path, data)
        p(f"    Uploaded to {device_path}")
        # Verify
        info = await afc.stat(device_path)
        p(f"    Verified: {info.get('st_size', 'unknown')} bytes on device")


asyncio.run(upload_via_afc())

# ── ATC session ──────────────────────────────────────────────────────────
conn = ATH.ATHostConnectionCreateWithLibrary(cfstr("com.mediaporter.sync"), cfstr(udid), 0)
if not conn:
    p("[-] Connection failed")
    sys.exit(1)

# Step 2: SendHostInfo
p("\n[2] SendHostInfo")
hostname = os.uname().nodename.split(".")[0]
hi = cfdict(
    LibraryID=cfstr("MEDIAPORTER00001"),
    SyncHostName=cfstr(hostname),
    SyncedDataclasses=CF.CFArrayCreateMutable(kCFAllocatorDefault, 0, kCFTypeArrayCallBacks),
    Version=cfstr("12.8"),
)
ATH.ATHostConnectionSendHostInfo(conn, hi)

# Step 3: Read until SyncAllowed
p("[3] Waiting for SyncAllowed...")
msg, name = read_until(conn, "SyncAllowed")
if name != "SyncAllowed":
    p(f"[-] Expected SyncAllowed, got {name}")
    sys.exit(1)

# Step 4: RequestingSync with Grappa
p("[4] RequestingSync + Grappa")
grappa_cf = CF.CFDataCreate(kCFAllocatorDefault, grappa_bytes, len(grappa_bytes))
hi_inner = cfdict(
    Grappa=grappa_cf,
    LibraryID=cfstr("MEDIAPORTER00001"),
    SyncHostName=cfstr(hostname),
    SyncedDataclasses=CF.CFArrayCreateMutable(kCFAllocatorDefault, 0, kCFTypeArrayCallBacks),
    Version=cfstr("12.8"),
)
dc = CF.CFArrayCreateMutable(kCFAllocatorDefault, 0, kCFTypeArrayCallBacks)
CF.CFArrayAppendValue(dc, cfstr("Media"))
CF.CFArrayAppendValue(dc, cfstr("Keybag"))
params = cfdict(
    DataclassAnchors=cfdict(Media=cfnum32(0)),
    Dataclasses=dc,
    HostInfo=hi_inner,
)
req = ATH.ATCFMessageCreate(0, cfstr("RequestingSync"), params)
err = ATH.ATHostConnectionSendMessage(conn, req)
p(f"    result: {err}")

# Step 5: Wait for ReadyForSync
p("[5] Waiting for ReadyForSync...")
msg, name = read_until(conn, "ReadyForSync")
if name != "ReadyForSync":
    p(f"[-] Expected ReadyForSync, got {name}")
    ATH.ATHostConnectionInvalidate(conn)
    sys.exit(1)
p("    Got ReadyForSync!")

# Step 6: MetadataSyncFinished
p("[6] SendMetadataSyncFinished")
sync_types = cfdict(Keybag=cfnum32(1), Media=cfnum32(1))
dc_anchors = cfdict(Media=cfnum32(0))
ATH.ATHostConnectionSendMetadataSyncFinished(conn, sync_types, dc_anchors)

# Step 7: FileBegin — use the high-level API matching third-party tool's signature
p("[7] SendFileBegin")
asset_id = random.randint(100000000000000000, 999999999999999999)
p(f"    AssetID: {asset_id}")
p(f"    DevicePath: {device_path}")

# Try the high-level SendFileBegin(conn, assetID, dataclass, fileSize, totalSize, fileSize)
asset_id_cf = cfnum64(asset_id)
file_size_cf = cfnum64(file_size)
err = ATH.ATHostConnectionSendFileBegin(conn, asset_id_cf, cfstr("Media"), file_size_cf, file_size_cf, file_size_cf)
p(f"    SendFileBegin: {err}")

# If high-level fails, try manual message
if err != 0 and err != 1:
    p("    Trying manual FileBegin message...")
    fb_params = cfdict(
        AssetID=cfnum64(asset_id),
        Dataclass=cfstr("Media"),
        FileSize=cfnum64(file_size),
        TotalSize=cfnum64(file_size),
    )
    fb_msg = ATH.ATCFMessageCreate(0, cfstr("FileBegin"), fb_params)
    err = ATH.ATHostConnectionSendMessage(conn, fb_msg)
    p(f"    Manual FileBegin: {err}")

# Read any responses
for i in range(3):
    msg, name = read_msg(conn, 3)
    if name in ["TIMEOUT", None]:
        p(f"    << {name}")
        break
    p(f"    << {name}")
    CF.CFShow(msg)

# Step 8: AssetCompleted
p("[8] SendAssetCompleted")
err = ATH.ATHostConnectionSendAssetCompleted(conn, asset_id_cf, cfstr("Media"), cfstr(device_path))
p(f"    SendAssetCompleted: {err}")

# If high-level fails, try manual message
if err != 0 and err != 1:
    p("    Trying manual FileComplete message...")
    fc_params = cfdict(
        AssetID=cfnum64(asset_id),
        Dataclass=cfstr("Media"),
        AssetPath=cfstr(device_path),
    )
    fc_msg = ATH.ATCFMessageCreate(0, cfstr("FileComplete"), fc_params)
    err = ATH.ATHostConnectionSendMessage(conn, fc_msg)
    p(f"    Manual FileComplete: {err}")

# Read final responses
p("    Reading responses...")
for i in range(5):
    msg, name = read_msg(conn, 5)
    if name in ["TIMEOUT", None]:
        p(f"    << {name}")
        break
    p(f"    << {name}")
    CF.CFShow(msg)

# ── Cleanup ──────────────────────────────────────────────────────────────
ATH.ATHostConnectionInvalidate(conn)
ATH.ATHostConnectionRelease(conn)
p("\n[+] Done — check TV app on device!")
