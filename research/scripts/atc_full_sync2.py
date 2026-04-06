#!/usr/bin/env python3
"""
Full ATC+AFC file sync — with sync plists.
Based on go-tunes flow: write sync plists to device BEFORE MetadataSyncFinished.

Usage: python3 scripts/atc_full_sync2.py <video.m4v> [grappa.bin]
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
import plistlib
import datetime

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
CF = ctypes.cdll.LoadLibrary("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
MD = ctypes.cdll.LoadLibrary("/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice")
ATH = ctypes.cdll.LoadLibrary("/System/Library/PrivateFrameworks/AirTrafficHost.framework/AirTrafficHost")
CIG_LIB = ctypes.cdll.LoadLibrary(os.path.join(os.path.dirname(__file__), "cig", "libcig.dylib"))
CIG_LIB.cig_calc.restype = c_int
CIG_LIB.cig_calc.argtypes = [c_char_p, c_char_p, c_int, c_char_p, POINTER(c_int)]

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
MD.AMDeviceNotificationSubscribe.argtypes = [AMDeviceNotificationCallback, c_uint, c_uint, c_void_p, POINTER(c_void_p)]
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


CF.CFDictionaryGetValue.restype = c_void_p
CF.CFDictionaryGetValue.argtypes = [c_void_p, c_void_p]
CF.CFDataGetBytePtr.restype = ctypes.POINTER(ctypes.c_ubyte)
CF.CFDataGetBytePtr.argtypes = [c_void_p]
CF.CFDataGetLength.restype = c_long
CF.CFDataGetLength.argtypes = [c_void_p]
CF.CFGetTypeID.restype = c_long
CF.CFGetTypeID.argtypes = [c_void_p]
CF.CFDictionaryGetTypeID.restype = c_long
CF.CFDataGetTypeID.restype = c_long


def compute_cig(device_grappa_bytes, plist_bytes):
    """Compute CIG signature from device Grappa + plist bytes."""
    cig_out = ctypes.create_string_buffer(21)
    cig_len = c_int(21)
    ret = CIG_LIB.cig_calc(device_grappa_bytes, plist_bytes, len(plist_bytes), cig_out, byref(cig_len))
    if ret == 1:
        return cig_out.raw[:cig_len.value]
    return None


def extract_device_grappa(msg):
    """Extract device Grappa bytes from ReadyForSync message."""
    device_info = ATH.ATCFMessageGetParam(msg, cfstr("DeviceInfo"))
    if not device_info:
        return None
    if CF.CFGetTypeID(device_info) != CF.CFDictionaryGetTypeID():
        return None
    grappa_data = CF.CFDictionaryGetValue(device_info, cfstr("Grappa"))
    if not grappa_data:
        return None
    if CF.CFGetTypeID(grappa_data) != CF.CFDataGetTypeID():
        return None
    length = CF.CFDataGetLength(grappa_data)
    ptr = CF.CFDataGetBytePtr(grappa_data)
    return bytes(ptr[:length])


def cfstr(s):
    return CF.CFStringCreateWithCString(kCFAllocatorDefault, s.encode("utf-8"), 0x08000100)

def cfstr_to_str(cf):
    if not cf: return None
    buf = ctypes.create_string_buffer(4096)
    return buf.value.decode("utf-8") if CF.CFStringGetCString(cf, buf, 4096, 0x08000100) else None

def cfnum32(v):
    val = ctypes.c_int32(v)
    return CF.CFNumberCreate(kCFAllocatorDefault, 3, byref(val))

def cfnum64(v):
    val = ctypes.c_int64(v)
    return CF.CFNumberCreate(kCFAllocatorDefault, 4, byref(val))

def cfdict(**kwargs):
    d = CF.CFDictionaryCreateMutable(kCFAllocatorDefault, 0, kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks)
    for k, v in kwargs.items():
        CF.CFDictionarySetValue(d, cfstr(k), v)
    return d

def read_msg(conn, to=8):
    signal.alarm(to)
    try:
        msg = ATH.ATHostConnectionReadMessage(conn)
        signal.alarm(0)
        if not msg: return None, None
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
        if name == target: return msg, name
        if name == "SyncFailed":
            CF.CFShow(msg)
            return msg, name
    return None, "MAX_MSGS"

def random_4char():
    return "".join(random.choices(string.ascii_uppercase, k=4))


# ── Build sync plists ────────────────────────────────────────────────────
def build_dataclass_plist(sync_num, asset_id, title, duration_ms, device_path):
    """Dataclass-specific plist with insert_track operation."""
    return plistlib.dumps({
        "revision": sync_num,
        "timestamp": datetime.datetime.now(datetime.timezone.utc),
        "operations": [
            {
                "operation": "update_db_info",
                "pid": 0,
                "db_info": {
                    "audio_language": 0,
                    "subtitle_language": 0,
                    "primary_container_pid": 0,
                },
            },
            {
                "operation": "insert_track",
                "pid": asset_id,
                "item": {
                    "title": title,
                    "sort_name": title,
                    "total_time_ms": duration_ms,
                    "media_kind": 1024,  # Home Video (appears in TV app)
                },
                "track_info": {
                    "location": device_path,
                    "file_size": os.path.getsize(VIDEO_FILE),
                },
            },
        ],
    }, fmt=plistlib.FMT_XML)


def build_media_operations_plist(sync_num):
    """Generic media operations plist (needs CIG sidecar)."""
    return plistlib.dumps({
        "revision": sync_num,
        "timestamp": datetime.datetime.now(datetime.timezone.utc),
        "operations": [
            {
                "operation": "update_db_info",
                "pid": 0,
                "db_info": {
                    "audio_language": 0,
                    "subtitle_language": 0,
                    "primary_container_pid": 0,
                },
            },
        ],
    }, fmt=plistlib.FMT_XML)


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
    if found[0]: break
if not found[0]:
    p("[-] No device"); sys.exit(1)

udid = found[1]
p(f"[+] Device: {udid}")

with open(GRAPPA_FILE, "rb") as f:
    grappa_bytes = f.read()

file_size = os.path.getsize(VIDEO_FILE)
file_name = os.path.splitext(os.path.basename(VIDEO_FILE))[0]
p(f"[+] File: {VIDEO_FILE} ({file_size} bytes)")

# ── ATC: Connect and handshake ───────────────────────────────────────────
conn = ATH.ATHostConnectionCreateWithLibrary(cfstr("com.mediaporter.sync"), cfstr(udid), 0)
hostname = os.uname().nodename.split(".")[0]

p("\n[1] SendHostInfo")
ATH.ATHostConnectionSendHostInfo(conn, cfdict(
    LibraryID=cfstr("MEDIAPORTER00001"), SyncHostName=cfstr(hostname),
    SyncedDataclasses=CF.CFArrayCreateMutable(kCFAllocatorDefault, 0, kCFTypeArrayCallBacks),
    Version=cfstr("12.8")))

p("[2] Waiting for SyncAllowed...")
msg, name = read_until(conn, "SyncAllowed")
if name != "SyncAllowed":
    p(f"[-] Expected SyncAllowed, got {name}"); sys.exit(1)

p("[3] RequestingSync + Grappa")
grappa_cf = CF.CFDataCreate(kCFAllocatorDefault, grappa_bytes, len(grappa_bytes))
hi = cfdict(
    Grappa=grappa_cf, LibraryID=cfstr("MEDIAPORTER00001"),
    SyncHostName=cfstr(hostname),
    SyncedDataclasses=CF.CFArrayCreateMutable(kCFAllocatorDefault, 0, kCFTypeArrayCallBacks),
    Version=cfstr("12.8"))
dc = CF.CFArrayCreateMutable(kCFAllocatorDefault, 0, kCFTypeArrayCallBacks)
CF.CFArrayAppendValue(dc, cfstr("Media"))
CF.CFArrayAppendValue(dc, cfstr("Keybag"))
req = ATH.ATCFMessageCreate(0, cfstr("RequestingSync"),
    cfdict(DataclassAnchors=cfdict(Media=cfnum32(0)), Dataclasses=dc, HostInfo=hi))
ATH.ATHostConnectionSendMessage(conn, req)

p("[4] Waiting for ReadyForSync...")
msg, name = read_until(conn, "ReadyForSync")
if name != "ReadyForSync":
    p(f"[-] Expected ReadyForSync, got {name}"); sys.exit(1)

# Extract device Grappa
device_grappa = extract_device_grappa(msg)
if device_grappa:
    p(f"    Device Grappa: {len(device_grappa)} bytes")
else:
    p("    WARNING: No device Grappa — CIG will fail")
    device_grappa = bytes(83)

# TODO: extract syncNum from DataclassAnchors.Media properly
sync_num = 12

# ── Generate asset details ───────────────────────────────────────────────
asset_id = random.randint(100000000000000000, 999999999999999999)
slot = f"F{random.randint(0, 49):02d}"
fname = f"{random_4char()}.mp4"
device_path = f"/iTunes_Control/Music/{slot}/{fname}"
p(f"\n[5] Asset: id={asset_id}, path={device_path}")

# ── AFC: Upload file + write sync plists ─────────────────────────────────
p("[6] AFC: Upload file + sync plists")

dc_plist = build_dataclass_plist(sync_num, asset_id, file_name, 10000, device_path)
media_plist = build_media_operations_plist(sync_num)

# Compute CIG from device Grappa + media plist
cig = compute_cig(device_grappa, media_plist)
if cig:
    p(f"    CIG: {len(cig)} bytes ({cig.hex()[:20]}...)")
else:
    p("    CIG FAILED — sync may not work")


async def afc_operations():
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.afc import AfcService

    ld = await create_using_usbmux()
    async with AfcService(ld) as afc:
        # Upload video file
        try:
            await afc.makedirs(f"/iTunes_Control/Music/{slot}")
        except Exception:
            pass
        with open(VIDEO_FILE, "rb") as f:
            await afc.set_file_contents(device_path, f.read())
        p(f"    Video → {device_path}")

        # Dataclass sync plist (no CIG)
        try:
            await afc.makedirs("/iTunes_Control/Music/Sync")
        except Exception:
            pass
        await afc.set_file_contents(
            f"/iTunes_Control/Music/Sync/Sync_{sync_num:08d}.plist", dc_plist
        )
        p(f"    DC plist → Music/Sync/")

        # Media operations plist + CIG sidecar
        try:
            await afc.makedirs("/iTunes_Control/Sync/Media")
        except Exception:
            pass
        await afc.set_file_contents(
            f"/iTunes_Control/Sync/Media/Sync_{sync_num:08d}.plist", media_plist
        )
        if cig:
            await afc.set_file_contents(
                f"/iTunes_Control/Sync/Media/Sync_{sync_num:08d}.plist.cig", cig
            )
        p(f"    Media plist + CIG → Sync/Media/")


asyncio.run(afc_operations())

# ── ATC: MetadataSyncFinished ────────────────────────────────────────────
p("\n[7] SendMetadataSyncFinished")
sync_types = cfdict(Keybag=cfnum32(1), Media=cfnum32(1))
# go-tunes passes anchor as string
dc_anchors = cfdict(Media=cfstr(str(sync_num)))
ATH.ATHostConnectionSendMetadataSyncFinished(conn, sync_types, dc_anchors)

# ── Read responses — expect AssetManifest ────────────────────────────────
p("[8] Reading responses (expect AssetManifest)...")
for i in range(8):
    msg, name = read_msg(conn, 8)
    if name in ["TIMEOUT", None]:
        p(f"    << {name}")
        break
    p(f"    << {name}")
    CF.CFShow(msg)

    if name == "AssetManifest":
        p("    *** GOT ASSET MANIFEST! Device wants files! ***")
        # Send AssetCompleted for our file
        p("\n[9] SendAssetCompleted")
        asset_id_cf = cfnum64(asset_id)
        err = ATH.ATHostConnectionSendAssetCompleted(conn, asset_id_cf, cfstr("Media"), cfstr(device_path))
        p(f"    result: {err}")
        # If high-level fails, try manual
        if err != 0 and err != 1:
            fc = ATH.ATCFMessageCreate(0, cfstr("FileComplete"), cfdict(
                AssetID=cfnum64(asset_id), Dataclass=cfstr("Media"), AssetPath=cfstr(device_path)))
            err = ATH.ATHostConnectionSendMessage(conn, fc)
            p(f"    Manual FileComplete: {err}")
        continue

    if name == "SyncFinished":
        p("    Sync finished (may have succeeded or failed)")
        break

# Read remaining
for i in range(3):
    msg, name = read_msg(conn, 5)
    if name in ["TIMEOUT", None]:
        p(f"    << {name}")
        break
    p(f"    << {name}")
    CF.CFShow(msg)

ATH.ATHostConnectionInvalidate(conn)
ATH.ATHostConnectionRelease(conn)
p("\n[+] Done — check TV app on device!")
