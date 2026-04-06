#!/usr/bin/env python3
"""
ATC file sync using replayed Grappa blob.
Replicates third-party tool's exact flow from LLDB traces.

Usage: python3 scripts/atc_sync_file.py <video_file> [grappa_blob]
"""
import ctypes
from ctypes import (
    c_void_p, c_char_p, c_int, c_uint, c_long, c_int64,
    CFUNCTYPE, POINTER, byref, cast,
)
import signal
import sys
import os
import random

VIDEO_FILE = sys.argv[1] if len(sys.argv) > 1 else None
GRAPPA_FILE = sys.argv[2] if len(sys.argv) > 2 else "/tmp/grappa.bin"

if not VIDEO_FILE:
    print("Usage: python3 scripts/atc_sync_file.py <video_file> [grappa_blob]")
    sys.exit(1)
if not os.path.exists(VIDEO_FILE):
    print(f"File not found: {VIDEO_FILE}")
    sys.exit(1)
if not os.path.exists(GRAPPA_FILE):
    print(f"Grappa blob not found: {GRAPPA_FILE}")
    sys.exit(1)


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
ATH.ATHostConnectionSendMetadataSyncFinished.argtypes = [
    c_void_p, c_void_p, c_void_p,
]
ATH.ATHostConnectionSendFileBegin.restype = c_int
ATH.ATHostConnectionSendFileBegin.argtypes = [
    c_void_p, c_void_p, c_void_p, c_void_p, c_void_p, c_void_p,
]
ATH.ATHostConnectionSendAssetCompleted.restype = c_int
ATH.ATHostConnectionSendAssetCompleted.argtypes = [
    c_void_p, c_void_p, c_void_p, c_void_p,
]
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
    return CF.CFStringCreateWithCString(
        kCFAllocatorDefault, s.encode("utf-8"), 0x08000100
    )


def cfstr_to_str(cf):
    if not cf:
        return None
    buf = ctypes.create_string_buffer(4096)
    if CF.CFStringGetCString(cf, buf, 4096, 0x08000100):
        return buf.value.decode("utf-8")
    return None


def cfnum32(v):
    val = ctypes.c_int32(v)
    return CF.CFNumberCreate(kCFAllocatorDefault, 3, byref(val))


def cfnum64(v):
    val = ctypes.c_int64(v)
    return CF.CFNumberCreate(kCFAllocatorDefault, 4, byref(val))


def cfdict(**kwargs):
    d = CF.CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0,
        kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks,
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
    """Read messages until we get the target command name."""
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
    p("[-] No device found")
    sys.exit(1)

udid = found[1]
p(f"[+] Device: {udid}")

# ── Load Grappa blob ─────────────────────────────────────────────────────
with open(GRAPPA_FILE, "rb") as f:
    grappa_bytes = f.read()
p(f"[+] Grappa: {len(grappa_bytes)} bytes from {GRAPPA_FILE}")

file_size = os.path.getsize(VIDEO_FILE)
p(f"[+] File: {VIDEO_FILE} ({file_size} bytes)")

# ── Create connection ────────────────────────────────────────────────────
conn = ATH.ATHostConnectionCreateWithLibrary(
    cfstr("com.mediaporter.sync"), cfstr(udid), 0
)
if not conn:
    p("[-] Connection failed")
    sys.exit(1)

# ══════════════════════════════════════════════════════════════════════════
# Step 1: SendHostInfo (third-party tool-style minimal)
# ══════════════════════════════════════════════════════════════════════════
p("\n[1] SendHostInfo")
host_info = cfdict(
    LibraryID=cfstr("MEDIAPORTER00001"),
    SyncHostName=cfstr(os.uname().nodename.split(".")[0]),
    SyncedDataclasses=CF.CFArrayCreateMutable(
        kCFAllocatorDefault, 0, kCFTypeArrayCallBacks
    ),
    Version=cfstr("12.8"),
)
ATH.ATHostConnectionSendHostInfo(conn, host_info)

# ══════════════════════════════════════════════════════════════════════════
# Step 2: Read device messages until SyncAllowed
# ══════════════════════════════════════════════════════════════════════════
p("[2] Reading device messages...")
msg, name = read_until(conn, "SyncAllowed")
if name != "SyncAllowed":
    p(f"[-] Expected SyncAllowed, got {name}")
    sys.exit(1)

# ══════════════════════════════════════════════════════════════════════════
# Step 3: Send RequestingSync with captured Grappa
# ══════════════════════════════════════════════════════════════════════════
p("[3] SendMessage(RequestingSync + Grappa)")
grappa_cf = CF.CFDataCreate(kCFAllocatorDefault, grappa_bytes, len(grappa_bytes))

hi_inner = cfdict(
    Grappa=grappa_cf,
    LibraryID=cfstr("MEDIAPORTER00001"),
    SyncHostName=cfstr(os.uname().nodename.split(".")[0]),
    SyncedDataclasses=CF.CFArrayCreateMutable(
        kCFAllocatorDefault, 0, kCFTypeArrayCallBacks
    ),
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

# ══════════════════════════════════════════════════════════════════════════
# Step 4: Read until ReadyForSync
# ══════════════════════════════════════════════════════════════════════════
p("[4] Waiting for ReadyForSync...")
msg, name = read_until(conn, "ReadyForSync")
if name == "SyncFailed":
    p("[-] Sync failed (Grappa rejected?)")
    ATH.ATHostConnectionInvalidate(conn)
    sys.exit(1)
if name != "ReadyForSync":
    p(f"[-] Expected ReadyForSync, got {name}")
    ATH.ATHostConnectionInvalidate(conn)
    sys.exit(1)

# Extract anchor from ReadyForSync
p("    Got ReadyForSync!")
CF.CFShow(msg)

# ══════════════════════════════════════════════════════════════════════════
# Step 5: SendMetadataSyncFinished
# ══════════════════════════════════════════════════════════════════════════
p("[5] SendMetadataSyncFinished")
sync_types = cfdict(Keybag=cfnum32(1), Media=cfnum32(1))
# Use anchor 0 — we're not continuing a previous sync
dc_anchors = cfdict(Media=cfnum32(0))
err = ATH.ATHostConnectionSendMetadataSyncFinished(conn, sync_types, dc_anchors)
p(f"    result: {err}")

# Read responses — third-party tool reads 3 messages here
p("    Reading responses...")
for i in range(3):
    msg, name = read_msg(conn, 5)
    if name in ["TIMEOUT", None]:
        p(f"    << {name}")
        break
    p(f"    << {name}")

# ══════════════════════════════════════════════════════════════════════════
# Step 6: SendFileBegin via manual ATCFMessage
# ══════════════════════════════════════════════════════════════════════════
p("[6] SendFileBegin")
asset_id = random.randint(100000000000000000, 999999999999999999)
p(f"    AssetID: {asset_id}")

fb_params = cfdict(
    AssetID=cfnum64(asset_id),
    Dataclass=cfstr("Media"),
    FileSize=cfnum64(file_size),
    TotalSize=cfnum64(file_size),
)
fb_msg = ATH.ATCFMessageCreate(0, cfstr("FileBegin"), fb_params)
err = ATH.ATHostConnectionSendMessage(conn, fb_msg)
p(f"    SendMessage(FileBegin): {err}")

# Read response
for i in range(3):
    msg, name = read_msg(conn, 5)
    if name in ["TIMEOUT", None]:
        p(f"    << {name}")
        break
    p(f"    << {name}")
    CF.CFShow(msg)

# ══════════════════════════════════════════════════════════════════════════
# Step 7: Send file data (FileProgress messages)
# ══════════════════════════════════════════════════════════════════════════
p("[7] Sending file data...")
CHUNK_SIZE = 256 * 1024  # 256KB chunks like third-party tool
with open(VIDEO_FILE, "rb") as f:
    sent = 0
    while True:
        chunk = f.read(CHUNK_SIZE)
        if not chunk:
            break
        sent += len(chunk)
        progress = sent / file_size

        chunk_cf = CF.CFDataCreate(kCFAllocatorDefault, chunk, len(chunk))
        progress_params = cfdict(
            AssetID=cfnum64(asset_id),
            AssetProgress=cfnum64(sent),  # bytes sent
            Dataclass=cfstr("Media"),
            OverallProgress=cfnum64(sent),
        )
        prog_msg = ATH.ATCFMessageCreate(0, cfstr("FileProgress"), progress_params)
        # TODO: The actual file data may need to go through AFC, not as message params
        err = ATH.ATHostConnectionSendMessage(conn, prog_msg)
        p(f"    Sent {sent}/{file_size} ({progress:.0%}) err={err}")

# ══════════════════════════════════════════════════════════════════════════
# Step 8: SendAssetCompleted
# ══════════════════════════════════════════════════════════════════════════
p("[8] SendAssetCompleted")
fc_params = cfdict(
    AssetID=cfnum64(asset_id),
    Dataclass=cfstr("Media"),
)
fc_msg = ATH.ATCFMessageCreate(0, cfstr("FileComplete"), fc_params)
err = ATH.ATHostConnectionSendMessage(conn, fc_msg)
p(f"    SendMessage(FileComplete): {err}")

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
p("\n[+] Done")
