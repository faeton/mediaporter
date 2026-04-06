#!/usr/bin/env python3
"""
CRITICAL TEST: FileBegin returned success (err=1) and no SyncFailed!
Device might be waiting for actual file data.

Send: FileBegin → file data bytes → FileComplete/AssetCompleted
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
kCFTypeArrayCallBacks = c_void_p.in_dll(CF, 'kCFTypeArrayCallBacks')

CF.CFStringCreateWithCString.restype = c_void_p
CF.CFStringCreateWithCString.argtypes = [c_void_p, c_char_p, c_uint]
CF.CFStringGetCString.restype = ctypes.c_bool
CF.CFStringGetCString.argtypes = [c_void_p, c_char_p, c_int, c_uint]
CF.CFDictionaryCreateMutable.restype = c_void_p
CF.CFDictionaryCreateMutable.argtypes = [c_void_p, c_int, c_void_p, c_void_p]
CF.CFDictionarySetValue.restype = None
CF.CFDictionarySetValue.argtypes = [c_void_p, c_void_p, c_void_p]
CF.CFArrayGetCount.restype = c_int
CF.CFArrayGetCount.argtypes = [c_void_p]
CF.CFArrayGetValueAtIndex.restype = c_void_p
CF.CFArrayGetValueAtIndex.argtypes = [c_void_p, c_int]
CF.CFNumberCreate.restype = c_void_p
CF.CFNumberCreate.argtypes = [c_void_p, c_int, c_void_p]
CF.CFShow.restype = None
CF.CFShow.argtypes = [c_void_p]
CF.CFDataCreate.restype = c_void_p
CF.CFDataCreate.argtypes = [c_void_p, c_void_p, c_int64]

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

MD.AMDCreateDeviceList.restype = c_void_p; MD.AMDCreateDeviceList.argtypes = []
MD.AMDeviceCopyDeviceIdentifier.restype = c_void_p; MD.AMDeviceCopyDeviceIdentifier.argtypes = [c_void_p]
MD.AMDeviceConnect.restype = c_int; MD.AMDeviceConnect.argtypes = [c_void_p]
MD.AMDeviceValidatePairing.restype = c_int; MD.AMDeviceValidatePairing.argtypes = [c_void_p]
MD.AMDeviceStartSession.restype = c_int; MD.AMDeviceStartSession.argtypes = [c_void_p]
MD.AMDeviceSecureStartService.restype = c_int
MD.AMDeviceSecureStartService.argtypes = [c_void_p, c_void_p, c_void_p, POINTER(c_void_p)]
MD.AMDServiceConnectionGetSocket.restype = c_int
MD.AMDServiceConnectionGetSocket.argtypes = [c_void_p]
MD.AMDServiceConnectionSend.restype = c_int
MD.AMDServiceConnectionSend.argtypes = [c_void_p, c_void_p, c_uint]
MD.AMDServiceConnectionReceive.restype = c_int
MD.AMDServiceConnectionReceive.argtypes = [c_void_p, c_void_p, c_uint]

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

# Also need AMDServiceConnection raw send for the ATC raw socket approach
ATH.ATHostAMDeviceSocketCreate.restype = c_void_p
ATH.ATHostAMDeviceSocketCreate.argtypes = [c_void_p, c_void_p]
ATH.ATHostAMDeviceSocketWrite.restype = c_int
ATH.ATHostAMDeviceSocketWrite.argtypes = [c_void_p, c_void_p, c_uint]

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
    err = ATH.ATHostConnectionSendMessage(conn, msg)
    return err


# ── Setup ─────────────────────────────────────────────────────────────────
test_file = "/Users/faeton/Sites/mediaporter/test_fixtures/test_h264_aac.mp4"
if not os.path.exists(test_file):
    for f in os.listdir("/Users/faeton/Sites/mediaporter/test_fixtures/"):
        if f.endswith(('.m4v', '.mp4')):
            test_file = f"/Users/faeton/Sites/mediaporter/test_fixtures/{f}"
            break

file_size = os.path.getsize(test_file)
file_name = os.path.basename(test_file)
p(f"[+] File: {file_name} ({file_size} bytes)")

# Read file data
with open(test_file, 'rb') as f:
    file_data = f.read()
p(f"[+] File data loaded: {len(file_data)} bytes")

# Device
device_list = MD.AMDCreateDeviceList()
device = CF.CFArrayGetValueAtIndex(device_list, 0)
udid = cfstr_to_str(MD.AMDeviceCopyDeviceIdentifier(device))
p(f"[+] Device: {udid}")

# ── ATHostConnection ──────────────────────────────────────────────────────
conn = ATH.ATHostConnectionCreateWithLibrary(cfstr("com.softorino.bigsync"), cfstr(udid), 0)
p(f"[+] conn={hex(conn) if conn else 'NULL'}")

# Read initial messages
session = 0
for i in range(5):
    msg, name = read_msg(conn, timeout_sec=5)
    if name in ["TIMEOUT", None]: break
    session = ATH.ATCFMessageGetSessionNumber(msg)
    p(f"  << {name} (session={session})")

# ── Send HostInfo ─────────────────────────────────────────────────────────
p("\n[*] Sending HostInfo...")
hi = CF.CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
    kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks)
CF.CFDictionarySetValue(hi, cfstr("HostName"), cfstr("third-party sync tool"))
CF.CFDictionarySetValue(hi, cfstr("HostID"), cfstr("com.softorino.bigsync"))
CF.CFDictionarySetValue(hi, cfstr("Version"), cfstr("12.13.2.3"))
err = send_raw(conn, session, "HostInfo", hi)
p(f"  HostInfo: {err}")

# ── Send FileBegin ────────────────────────────────────────────────────────
p("\n[*] Sending FileBegin...")
remote_path = f"iTunes_Control/Music/F00/{file_name}"
fb = CF.CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
    kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks)
CF.CFDictionarySetValue(fb, cfstr("Path"), cfstr(remote_path))
CF.CFDictionarySetValue(fb, cfstr("FileSize"), cfnum64(file_size))
CF.CFDictionarySetValue(fb, cfstr("TotalSize"), cfnum64(file_size))

err = send_raw(conn, session, "FileBegin", fb)
p(f"  FileBegin: {err}")

# Check for immediate response
msg, name = read_msg(conn, timeout_sec=3)
if name and name != "TIMEOUT":
    p(f"  << {name}")
    if name == "SyncFailed" or name == "FileError":
        ec = ATH.ATCFMessageGetParam(msg, cfstr("ErrorCode"))
        if ec: CF.CFShow(ec)
        p("[-] File rejected")
    elif name == "FileAccepted" or name == "ReadyForFile":
        p("[+] File accepted! Sending data...")
else:
    p(f"  No immediate response ({name}) — device might be waiting for data")

# ── Send file data ────────────────────────────────────────────────────────
# The ATC protocol might expect raw bytes after FileBegin
# Or it might expect them in a specific message format
# Let's try both approaches

p("\n[*] Approach A: Send FileProgress with data via raw message...")
# Maybe the data goes in a FileProgress message
chunk_size = 65536
offset = 0
chunks_sent = 0
while offset < len(file_data):
    chunk = file_data[offset:offset+chunk_size]

    fp = CF.CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
        kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks)

    # Create CFData from chunk
    chunk_buf = ctypes.create_string_buffer(chunk)
    cf_data = CF.CFDataCreate(kCFAllocatorDefault, chunk_buf, len(chunk))

    CF.CFDictionarySetValue(fp, cfstr("Data"), cf_data)
    CF.CFDictionarySetValue(fp, cfstr("Offset"), cfnum64(offset))
    CF.CFDictionarySetValue(fp, cfstr("Length"), cfnum64(len(chunk)))

    err = send_raw(conn, session, "FileProgress", fp)
    offset += len(chunk)
    chunks_sent += 1

    if chunks_sent <= 3 or chunks_sent % 10 == 0:
        p(f"  Chunk {chunks_sent}: offset={offset}/{file_size}, err={err}")

    # Check for any response
    if chunks_sent <= 2:
        rmsg, rname = read_msg(conn, timeout_sec=1)
        if rname and rname != "TIMEOUT":
            p(f"  << {rname}")
            if rname in ["SyncFailed", "FileError", "ConnectionInvalid"]:
                ec = ATH.ATCFMessageGetParam(rmsg, cfstr("ErrorCode"))
                if ec: CF.CFShow(ec)
                p("[-] Transfer rejected")
                break

p(f"  Total chunks sent: {chunks_sent}")

# ── Send FileComplete/AssetCompleted ──────────────────────────────────────
p("\n[*] Sending FileComplete...")
fc = CF.CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
    kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks)
CF.CFDictionarySetValue(fc, cfstr("Path"), cfstr(remote_path))
CF.CFDictionarySetValue(fc, cfstr("FileSize"), cfnum64(file_size))
err = send_raw(conn, session, "FileComplete", fc)
p(f"  FileComplete: {err}")

# Read response
for i in range(5):
    msg, name = read_msg(conn, timeout_sec=5)
    if name in ["TIMEOUT", None]:
        p(f"  [{i}] {name or 'NULL'}")
        break
    p(f"  [{i}] << {name}")
    if name == "SyncFinished":
        p("[+] *** SYNC FINISHED! Check TV app! ***")
        break

ATH.ATHostConnectionInvalidate(conn)
ATH.ATHostConnectionRelease(conn)
p("\n[+] Done")
