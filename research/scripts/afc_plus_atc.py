#!/usr/bin/env python3
"""
third-party tool's actual flow (hypothesis):
1. Push file via AFC to iTunes_Control/Music/Fxx/filename.m4v
2. Use ATHostConnection messages to register the file in the media library

third-party tool imports both AFC* and ATHostConnection* functions.
The AFC handles file data, ATHostConnection handles metadata registration.
"""
import ctypes
from ctypes import c_void_p, c_char_p, c_int, c_uint, c_int64, POINTER, byref
import signal, sys, os, struct, plistlib

def p(msg):
    print(msg, flush=True)

def timeout_handler(signum, frame):
    raise TimeoutError()
signal.signal(signal.SIGALRM, timeout_handler)

CF = ctypes.cdll.LoadLibrary('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
MD = ctypes.cdll.LoadLibrary('/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice')
ATH = ctypes.cdll.LoadLibrary('/System/Library/PrivateFrameworks/AirTrafficHost.framework/AirTrafficHost')

kCFAllocatorDefault = c_void_p.in_dll(CF, 'kCFAllocatorDefault')
kCFBooleanTrue = c_void_p.in_dll(CF, 'kCFBooleanTrue')
kCFTypeDictionaryKeyCallBacks = c_void_p.in_dll(CF, 'kCFTypeDictionaryKeyCallBacks')
kCFTypeDictionaryValueCallBacks = c_void_p.in_dll(CF, 'kCFTypeDictionaryValueCallBacks')

CF.CFStringCreateWithCString.restype = c_void_p
CF.CFStringCreateWithCString.argtypes = [c_void_p, c_char_p, c_uint]
CF.CFStringGetCString.restype = ctypes.c_bool
CF.CFStringGetCString.argtypes = [c_void_p, c_char_p, c_int, c_uint]
CF.CFDictionaryCreateMutable.restype = c_void_p
CF.CFDictionaryCreateMutable.argtypes = [c_void_p, c_int, c_void_p, c_void_p]
CF.CFDictionarySetValue.restype = None
CF.CFDictionarySetValue.argtypes = [c_void_p, c_void_p, c_void_p]
CF.CFArrayGetCount.restype = c_int; CF.CFArrayGetCount.argtypes = [c_void_p]
CF.CFArrayGetValueAtIndex.restype = c_void_p; CF.CFArrayGetValueAtIndex.argtypes = [c_void_p, c_int]
CF.CFNumberCreate.restype = c_void_p; CF.CFNumberCreate.argtypes = [c_void_p, c_int, c_void_p]
CF.CFShow.restype = None; CF.CFShow.argtypes = [c_void_p]

def cfstr(s):
    return CF.CFStringCreateWithCString(kCFAllocatorDefault, s.encode('utf-8'), 0x08000100)
def cfstr_to_str(cf):
    if not cf: return None
    buf = ctypes.create_string_buffer(4096)
    return buf.value.decode('utf-8') if CF.CFStringGetCString(cf, buf, 4096, 0x08000100) else None
def cfnum32(val):
    v = ctypes.c_int32(val); return CF.CFNumberCreate(kCFAllocatorDefault, 3, byref(v))
def cfnum64(val):
    v = ctypes.c_int64(val); return CF.CFNumberCreate(kCFAllocatorDefault, 4, byref(v))

# MobileDevice
MD.AMDCreateDeviceList.restype = c_void_p; MD.AMDCreateDeviceList.argtypes = []
MD.AMDeviceConnect.restype = c_int; MD.AMDeviceConnect.argtypes = [c_void_p]
MD.AMDeviceValidatePairing.restype = c_int; MD.AMDeviceValidatePairing.argtypes = [c_void_p]
MD.AMDeviceStartSession.restype = c_int; MD.AMDeviceStartSession.argtypes = [c_void_p]
MD.AMDeviceStopSession.restype = c_int; MD.AMDeviceStopSession.argtypes = [c_void_p]
MD.AMDeviceCopyDeviceIdentifier.restype = c_void_p; MD.AMDeviceCopyDeviceIdentifier.argtypes = [c_void_p]
MD.AMDeviceCopyValue.restype = c_void_p; MD.AMDeviceCopyValue.argtypes = [c_void_p, c_void_p, c_void_p]
MD.AMDeviceSecureStartService.restype = c_int
MD.AMDeviceSecureStartService.argtypes = [c_void_p, c_void_p, c_void_p, POINTER(c_void_p)]

# AFC functions
MD.AFCConnectionOpen.restype = c_int
MD.AFCConnectionOpen.argtypes = [c_int, c_uint, POINTER(c_void_p)]  # socket, timeout, &afc_conn

MD.AFCDirectoryCreate.restype = c_int
MD.AFCDirectoryCreate.argtypes = [c_void_p, c_char_p]

MD.AFCFileRefOpen.restype = c_int
MD.AFCFileRefOpen.argtypes = [c_void_p, c_char_p, c_uint, POINTER(c_void_p)]  # conn, path, mode, &handle

MD.AFCFileRefWrite.restype = c_int
MD.AFCFileRefWrite.argtypes = [c_void_p, c_void_p, c_void_p, c_uint]  # conn, handle, data, len

MD.AFCFileRefClose.restype = c_int
MD.AFCFileRefClose.argtypes = [c_void_p, c_void_p]

MD.AFCConnectionClose.restype = c_int
MD.AFCConnectionClose.argtypes = [c_void_p]

MD.AMDServiceConnectionGetSocket.restype = c_int
MD.AMDServiceConnectionGetSocket.argtypes = [c_void_p]

# AirTrafficHost
ATH.ATHostConnectionCreateWithLibrary.restype = c_void_p
ATH.ATHostConnectionCreateWithLibrary.argtypes = [c_void_p, c_void_p, c_uint]
ATH.ATHostConnectionGetCurrentSessionNumber.restype = c_uint
ATH.ATHostConnectionGetCurrentSessionNumber.argtypes = [c_void_p]
ATH.ATHostConnectionSendMessage.restype = c_int
ATH.ATHostConnectionSendMessage.argtypes = [c_void_p, c_void_p]
ATH.ATHostConnectionReadMessage.restype = c_void_p
ATH.ATHostConnectionReadMessage.argtypes = [c_void_p]
ATH.ATHostConnectionInvalidate.restype = c_int
ATH.ATHostConnectionInvalidate.argtypes = [c_void_p]
ATH.ATHostConnectionRelease.restype = None
ATH.ATHostConnectionRelease.argtypes = [c_void_p]
ATH.ATCFMessageCreate.restype = c_void_p
ATH.ATCFMessageCreate.argtypes = [c_uint, c_void_p, c_void_p]
ATH.ATCFMessageGetName.restype = c_void_p
ATH.ATCFMessageGetName.argtypes = [c_void_p]
ATH.ATCFMessageGetParam.restype = c_void_p
ATH.ATCFMessageGetParam.argtypes = [c_void_p, c_void_p]
ATH.ATCFMessageGetSessionNumber.restype = c_uint
ATH.ATCFMessageGetSessionNumber.argtypes = [c_void_p]

def read_msg(conn, timeout_sec=5):
    signal.alarm(timeout_sec)
    try:
        msg = ATH.ATHostConnectionReadMessage(conn)
        signal.alarm(0)
        if not msg: return None, None
        name = cfstr_to_str(ATH.ATCFMessageGetName(msg))
        return msg, name
    except TimeoutError:
        signal.alarm(0)
        return None, "TIMEOUT"

def send_raw(conn, session, command, params):
    msg = ATH.ATCFMessageCreate(session, cfstr(command), params)
    if not msg: return -1
    return ATH.ATHostConnectionSendMessage(conn, msg)


# ── Setup ─────────────────────────────────────────────────────────────────
test_file = "/Users/faeton/Sites/mediaporter/test_fixtures/test_h264_aac.mp4"
if not os.path.exists(test_file):
    for f in sorted(os.listdir("/Users/faeton/Sites/mediaporter/test_fixtures/")):
        if f.endswith(('.m4v', '.mp4')):
            test_file = f"/Users/faeton/Sites/mediaporter/test_fixtures/{f}"
            break

file_size = os.path.getsize(test_file)
file_name = os.path.basename(test_file)
p(f"[+] File: {file_name} ({file_size} bytes)")

device_list = MD.AMDCreateDeviceList()
device = CF.CFArrayGetValueAtIndex(device_list, 0)
udid = cfstr_to_str(MD.AMDeviceCopyDeviceIdentifier(device))
p(f"[+] Device: {udid}")

MD.AMDeviceConnect(device)
MD.AMDeviceValidatePairing(device)
MD.AMDeviceStartSession(device)

# ══════════════════════════════════════════════════════════════════════════
# STEP 1: Push file via AFC
# ══════════════════════════════════════════════════════════════════════════
p("\n=== STEP 1: Push file via AFC ===")

afc_svc = c_void_p()
err = MD.AMDeviceSecureStartService(device, cfstr("com.apple.afc"), None, byref(afc_svc))
p(f"  AFC service: err={err}")

afc_sock = MD.AMDServiceConnectionGetSocket(afc_svc)
p(f"  AFC socket: {afc_sock}")

afc_conn = c_void_p()
err = MD.AFCConnectionOpen(afc_sock, 0, byref(afc_conn))
p(f"  AFCConnectionOpen: err={err}, conn={hex(afc_conn.value) if afc_conn.value else 'NULL'}")

if not afc_conn.value:
    p("[-] AFC connection failed")
    sys.exit(1)

# Create directory
remote_dir = b"iTunes_Control/Music/F00"
err = MD.AFCDirectoryCreate(afc_conn, remote_dir)
p(f"  mkdir {remote_dir.decode()}: {err}")

# Push file
remote_path = f"iTunes_Control/Music/F00/{file_name}".encode()
file_handle = c_void_p()
err = MD.AFCFileRefOpen(afc_conn, remote_path, 3, byref(file_handle))  # 3 = write/create
p(f"  AFCFileRefOpen({remote_path.decode()}): err={err}, handle={hex(file_handle.value) if file_handle.value else 'NULL'}")

if err == 0:
    with open(test_file, 'rb') as f:
        chunk_size = 65536
        total_written = 0
        while True:
            chunk = f.read(chunk_size)
            if not chunk:
                break
            buf = ctypes.create_string_buffer(chunk)
            err = MD.AFCFileRefWrite(afc_conn, file_handle, buf, len(chunk))
            if err != 0:
                p(f"  Write error: {err}")
                break
            total_written += len(chunk)

    p(f"  Written: {total_written}/{file_size} bytes")
    MD.AFCFileRefClose(afc_conn, file_handle)
    p("  File closed")
else:
    p(f"[-] AFCFileRefOpen failed: {err}")

MD.AFCConnectionClose(afc_conn)
p("  AFC closed")

# ══════════════════════════════════════════════════════════════════════════
# STEP 2: Use ATHostConnection to register the file
# ══════════════════════════════════════════════════════════════════════════
p("\n=== STEP 2: Register file via ATHostConnection ===")

# Need to reconnect device session for ATHostConnection
MD.AMDeviceStopSession(device)
MD.AMDeviceConnect(device)
MD.AMDeviceStartSession(device)

conn = ATH.ATHostConnectionCreateWithLibrary(cfstr("com.softorino.bigsync"), cfstr(udid), 0)
p(f"  conn={hex(conn) if conn else 'NULL'}")

# Read initial messages
session = 0
for i in range(5):
    msg, name = read_msg(conn, timeout_sec=5)
    if name in ["TIMEOUT", None]: break
    session = ATH.ATCFMessageGetSessionNumber(msg)
    p(f"  << {name} (session={session})")

# Send HostInfo
p("\n  Sending HostInfo...")
hi = CF.CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
    kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks)
CF.CFDictionarySetValue(hi, cfstr("HostName"), cfstr("third-party sync tool"))
CF.CFDictionarySetValue(hi, cfstr("HostID"), cfstr("com.softorino.bigsync"))
CF.CFDictionarySetValue(hi, cfstr("Version"), cfstr("12.13.2.3"))
err = send_raw(conn, session, "HostInfo", hi)
p(f"  HostInfo: {err}")

# Send FileComplete — file is already on device via AFC
# From ATC_PROTOCOL.md: "FileComplete" with asset info
p("\n  Sending FileComplete (file already on device)...")
location = f"F00/{file_name}"
fc = CF.CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
    kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks)
CF.CFDictionarySetValue(fc, cfstr("Path"), cfstr(f"iTunes_Control/Music/{location}"))
CF.CFDictionarySetValue(fc, cfstr("Location"), cfstr(location))
CF.CFDictionarySetValue(fc, cfstr("FileSize"), cfnum64(file_size))
CF.CFDictionarySetValue(fc, cfstr("DataClass"), cfstr("com.apple.Movies"))
CF.CFDictionarySetValue(fc, cfstr("AssetIdentifier"), cfstr(file_name))
# Media metadata
CF.CFDictionarySetValue(fc, cfstr("MediaType"), cfnum32(8192))   # Home Video
CF.CFDictionarySetValue(fc, cfstr("MediaKind"), cfnum32(1024))
CF.CFDictionarySetValue(fc, cfstr("Title"), cfstr("Test Video from mediaporter"))
CF.CFDictionarySetValue(fc, cfstr("Artist"), cfstr("mediaporter"))
err = send_raw(conn, session, "FileComplete", fc)
p(f"  FileComplete: {err}")

# Read response
for i in range(3):
    msg, name = read_msg(conn, timeout_sec=5)
    if name in ["TIMEOUT", None]:
        p(f"  [{i}] {name or 'NULL'}")
        break
    p(f"  [{i}] << {name}")

# Send AssetCompleted (from AMPDevicesAgent strings: "FileComplete for device %@, asset identifier...")
p("\n  Sending AssetCompleted...")
ac = CF.CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
    kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks)
CF.CFDictionarySetValue(ac, cfstr("AssetIdentifier"), cfstr(file_name))
CF.CFDictionarySetValue(ac, cfstr("DataClass"), cfstr("com.apple.Movies"))
CF.CFDictionarySetValue(ac, cfstr("Path"), cfstr(f"iTunes_Control/Music/{location}"))
CF.CFDictionarySetValue(ac, cfstr("Anchor"), cfstr("1"))
err = send_raw(conn, session, "AssetCompleted", ac)
p(f"  AssetCompleted: {err}")

# Send FinishedSyncingMetadata
p("\n  Sending FinishedSyncingMetadata...")
fsm = CF.CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
    kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks)
st = CF.CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
    kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks)
CF.CFDictionarySetValue(st, cfstr("com.apple.Movies"), kCFBooleanTrue)
CF.CFDictionarySetValue(fsm, cfstr("SyncTypes"), st)
anchors = CF.CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
    kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks)
CF.CFDictionarySetValue(fsm, cfstr("Anchors"), anchors)
CF.CFDictionarySetValue(fsm, cfstr("PurgeDataBytes"), cfnum64(0))
CF.CFDictionarySetValue(fsm, cfstr("FreeDiskBytes"), cfnum64(0))
err = send_raw(conn, session, "FinishedSyncingMetadata", fsm)
p(f"  FinishedSyncingMetadata: {err}")

# Read ALL responses
p("\n  Reading responses:")
for i in range(8):
    msg, name = read_msg(conn, timeout_sec=5)
    if name in ["TIMEOUT", None]:
        p(f"  [{i}] {name or 'NULL'}")
        break
    p(f"  [{i}] << {name}")
    if name == "SyncFinished":
        p("  *** SYNC FINISHED! ***")
        break
    if name == "SyncFailed":
        ec = ATH.ATCFMessageGetParam(msg, cfstr("ErrorCode"))
        if ec: CF.CFShow(ec)

ATH.ATHostConnectionInvalidate(conn)
ATH.ATHostConnectionRelease(conn)
p("\n[+] Done — CHECK TV APP!")
