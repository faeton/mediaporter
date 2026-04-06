#!/usr/bin/env python3
"""
Test: Use typed Send* functions and check if they actually work despite
returning non-zero. Maybe the return value is a session ID, not an error.

third-party tool uses: SendHostInfo, SendFileBegin, SendFileProgress,
SendAssetCompleted, SendMetadataSyncFinished, SendPing.
Let's try them in sequence with the tiny file.
"""
import ctypes
from ctypes import c_void_p, c_char_p, c_int, c_uint, c_int64, POINTER, byref
import signal, sys, os

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
CF.CFArrayGetCount.restype = c_int; CF.CFArrayGetCount.argtypes = [c_void_p]
CF.CFArrayGetValueAtIndex.restype = c_void_p; CF.CFArrayGetValueAtIndex.argtypes = [c_void_p, c_int]
CF.CFNumberCreate.restype = c_void_p; CF.CFNumberCreate.argtypes = [c_void_p, c_int, c_void_p]
CF.CFDataCreate.restype = c_void_p; CF.CFDataCreate.argtypes = [c_void_p, c_void_p, c_int64]
CF.CFShow.restype = None; CF.CFShow.argtypes = [c_void_p]
CF.CFArrayCreateMutable.restype = c_void_p
CF.CFArrayCreateMutable.argtypes = [c_void_p, c_int, c_void_p]
CF.CFArrayAppendValue.restype = None
CF.CFArrayAppendValue.argtypes = [c_void_p, c_void_p]

def cfstr(s): return CF.CFStringCreateWithCString(kCFAllocatorDefault, s.encode('utf-8'), 0x08000100)
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

# Typed ATHost functions — EXACTLY what third-party tool imports
ATH.ATHostConnectionCreateWithLibrary.restype = c_void_p
ATH.ATHostConnectionCreateWithLibrary.argtypes = [c_void_p, c_void_p, c_uint]
ATH.ATHostConnectionGetCurrentSessionNumber.restype = c_uint
ATH.ATHostConnectionGetCurrentSessionNumber.argtypes = [c_void_p]
ATH.ATHostConnectionGetGrappaSessionId.restype = c_uint
ATH.ATHostConnectionGetGrappaSessionId.argtypes = [c_void_p]

ATH.ATHostConnectionSendHostInfo.restype = c_int
ATH.ATHostConnectionSendHostInfo.argtypes = [c_void_p, c_void_p]

ATH.ATHostConnectionSendFileBegin.restype = c_int
ATH.ATHostConnectionSendFileBegin.argtypes = [c_void_p, c_void_p]

ATH.ATHostConnectionSendFileProgress.restype = c_int
ATH.ATHostConnectionSendFileProgress.argtypes = [c_void_p, c_void_p]

ATH.ATHostConnectionSendFileError.restype = c_int
ATH.ATHostConnectionSendFileError.argtypes = [c_void_p, c_void_p]

ATH.ATHostConnectionSendAssetCompleted.restype = c_int
ATH.ATHostConnectionSendAssetCompleted.argtypes = [c_void_p, c_void_p, c_void_p, c_void_p]

ATH.ATHostConnectionSendMetadataSyncFinished.restype = c_int
ATH.ATHostConnectionSendMetadataSyncFinished.argtypes = [c_void_p, c_void_p, c_void_p]

ATH.ATHostConnectionSendPing.restype = c_int
ATH.ATHostConnectionSendPing.argtypes = [c_void_p]

ATH.ATHostConnectionSendMessage.restype = c_int
ATH.ATHostConnectionSendMessage.argtypes = [c_void_p, c_void_p]

ATH.ATHostConnectionReadMessage.restype = c_void_p
ATH.ATHostConnectionReadMessage.argtypes = [c_void_p]

ATH.ATHostConnectionInvalidate.restype = c_int
ATH.ATHostConnectionInvalidate.argtypes = [c_void_p]
ATH.ATHostConnectionRelease.restype = None
ATH.ATHostConnectionRelease.argtypes = [c_void_p]

ATH.ATCFMessageGetName.restype = c_void_p; ATH.ATCFMessageGetName.argtypes = [c_void_p]
ATH.ATCFMessageGetParam.restype = c_void_p; ATH.ATCFMessageGetParam.argtypes = [c_void_p, c_void_p]
ATH.ATCFMessageGetSessionNumber.restype = c_uint; ATH.ATCFMessageGetSessionNumber.argtypes = [c_void_p]
ATH.ATCFMessageCreate.restype = c_void_p; ATH.ATCFMessageCreate.argtypes = [c_uint, c_void_p, c_void_p]

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


# ── Setup ─────────────────────────────────────────────────────────────────
test_file = "/tmp/tiny_test.m4v"
file_size = os.path.getsize(test_file)
p(f"[+] File: {os.path.basename(test_file)} ({file_size} bytes)")
with open(test_file, 'rb') as f:
    file_data = f.read()

dl = MD.AMDCreateDeviceList()
d = CF.CFArrayGetValueAtIndex(dl, 0)
udid = cfstr_to_str(MD.AMDeviceCopyDeviceIdentifier(d))
p(f"[+] Device: {udid}")

# ── Create connection ─────────────────────────────────────────────────────
conn = ATH.ATHostConnectionCreateWithLibrary(cfstr("com.softorino.bigsync"), cfstr(udid), 0)
p(f"[+] conn={hex(conn) if conn else 'NULL'}")
p(f"    grappa={ATH.ATHostConnectionGetGrappaSessionId(conn)}")

# Drain initial messages
session = 0
for i in range(5):
    msg, name = read_msg(conn, timeout_sec=5)
    if name in ["TIMEOUT", None]: break
    session = ATH.ATCFMessageGetSessionNumber(msg)
    p(f"  << {name} (session={session})")
    if name == "SyncAllowed": break

p(f"    grappa after msgs={ATH.ATHostConnectionGetGrappaSessionId(conn)}")
p(f"    session={ATH.ATHostConnectionGetCurrentSessionNumber(conn)}")

# ── Step 1: SendHostInfo (typed) ──────────────────────────────────────────
p("\n[*] Step 1: SendHostInfo (typed function)")
hi = CF.CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
    kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks)
CF.CFDictionarySetValue(hi, cfstr("HostName"), cfstr("third-party sync tool"))
CF.CFDictionarySetValue(hi, cfstr("HostID"), cfstr("com.softorino.bigsync"))
CF.CFDictionarySetValue(hi, cfstr("Version"), cfstr("12.13.2.3"))
err = ATH.ATHostConnectionSendHostInfo(conn, hi)
p(f"  ret={err} (0x{err & 0xFFFFFFFF:08x})")

# Read any response
msg, name = read_msg(conn, timeout_sec=3)
p(f"  response: {name}")

# ── Step 2: SendFileBegin (typed) ─────────────────────────────────────────
p("\n[*] Step 2: SendFileBegin (typed function)")
# The assertion said "dataclass" is required on the connection.
# Maybe we need to set it via a RequestingSync or something first.
# But third-party tool doesn't import SendSyncRequest...
# Let's try sending a raw RequestingSync via SendMessage first.
p("  Sending raw RequestingSync first...")
rs_params = CF.CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
    kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks)
dc = CF.CFArrayCreateMutable(kCFAllocatorDefault, 0, kCFTypeArrayCallBacks)
CF.CFArrayAppendValue(dc, cfstr("com.apple.media"))
CF.CFDictionarySetValue(rs_params, cfstr("DataClasses"), dc)
rs_msg = ATH.ATCFMessageCreate(session, cfstr("RequestingSync"), rs_params)
err = ATH.ATHostConnectionSendMessage(conn, rs_msg)
p(f"  RequestingSync via SendMessage: {err}")

# Read response (might be SyncFailed or SyncAllowed)
msg, name = read_msg(conn, timeout_sec=5)
p(f"  response: {name}")
if name == "SyncFailed":
    ec = ATH.ATCFMessageGetParam(msg, cfstr("ErrorCode"))
    if ec: CF.CFShow(ec)
if name == "SyncAllowed":
    p("  Got SyncAllowed! Trying BeginSync...")
    bs_params = CF.CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
        kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks)
    st = CF.CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
        kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks)
    CF.CFDictionarySetValue(st, cfstr("com.apple.Movies"), kCFBooleanTrue)
    CF.CFDictionarySetValue(bs_params, cfstr("SyncTypes"), st)
    bs_msg = ATH.ATCFMessageCreate(session, cfstr("BeginSync"), bs_params)
    err = ATH.ATHostConnectionSendMessage(conn, bs_msg)
    p(f"  BeginSync: {err}")

    msg, name = read_msg(conn, timeout_sec=5)
    p(f"  response: {name}")
    if name == "ReadyForSync":
        p("  *** READY FOR SYNC! ***")

# Check grappa state
p(f"\n  grappa now={ATH.ATHostConnectionGetGrappaSessionId(conn)}")

# Now try SendFileBegin
p("\n  Trying SendFileBegin (typed)...")
fb = CF.CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
    kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks)
CF.CFDictionarySetValue(fb, cfstr("Path"), cfstr("iTunes_Control/Music/F00/tiny_test.m4v"))
CF.CFDictionarySetValue(fb, cfstr("FileSize"), cfnum64(file_size))
CF.CFDictionarySetValue(fb, cfstr("TotalSize"), cfnum64(file_size))
CF.CFDictionarySetValue(fb, cfstr("TransferType"), cfnum32(0))

try:
    err = ATH.ATHostConnectionSendFileBegin(conn, fb)
    p(f"  SendFileBegin: {err} (0x{err & 0xFFFFFFFF:08x})")
except Exception as e:
    p(f"  SendFileBegin exception: {e}")

# ── Step 3: Send file data via SendFileProgress ──────────────────────────
p("\n[*] Step 3: SendFileProgress chunks")
chunk_size = 32768
offset = 0
for i in range(5):  # just a few chunks to test
    chunk = file_data[offset:offset+chunk_size]
    if not chunk: break

    fp = CF.CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
        kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks)

    chunk_buf = ctypes.create_string_buffer(chunk)
    cf_data = CF.CFDataCreate(kCFAllocatorDefault, chunk_buf, len(chunk))
    CF.CFDictionarySetValue(fp, cfstr("Data"), cf_data)
    CF.CFDictionarySetValue(fp, cfstr("FileSize"), cfnum64(file_size))
    CF.CFDictionarySetValue(fp, cfstr("Progress"), cfnum64(offset + len(chunk)))

    try:
        err = ATH.ATHostConnectionSendFileProgress(conn, fp)
        p(f"  Chunk {i}: {err} (0x{err & 0xFFFFFFFF:08x})")
    except Exception as e:
        p(f"  Chunk {i} exception: {e}")
        break

    offset += len(chunk)

# ── Step 4: SendAssetCompleted ────────────────────────────────────────────
p("\n[*] Step 4: SendAssetCompleted")
try:
    err = ATH.ATHostConnectionSendAssetCompleted(conn,
        cfstr("tiny_test.m4v"),           # asset identifier
        cfstr("com.apple.Movies"),         # data class
        None)                              # metadata dict
    p(f"  SendAssetCompleted: {err} (0x{err & 0xFFFFFFFF:08x})")
except Exception as e:
    p(f"  Exception: {e}")

# ── Step 5: SendMetadataSyncFinished ──────────────────────────────────────
p("\n[*] Step 5: SendMetadataSyncFinished")
fsm_types = CF.CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
    kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks)
CF.CFDictionarySetValue(fsm_types, cfstr("com.apple.Movies"), kCFBooleanTrue)
fsm_anchors = CF.CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
    kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks)

try:
    err = ATH.ATHostConnectionSendMetadataSyncFinished(conn, fsm_types, fsm_anchors)
    p(f"  SendMetadataSyncFinished: {err} (0x{err & 0xFFFFFFFF:08x})")
except Exception as e:
    p(f"  Exception: {e}")

# ── Read all responses ────────────────────────────────────────────────────
p("\n[*] Reading responses:")
for i in range(5):
    msg, name = read_msg(conn, timeout_sec=5)
    if name in ["TIMEOUT", None]:
        p(f"  [{i}] {name or 'NULL'}")
        break
    p(f"  [{i}] << {name}")
    if name == "SyncFailed":
        ec = ATH.ATCFMessageGetParam(msg, cfstr("ErrorCode"))
        if ec: CF.CFShow(ec)
    if name == "SyncFinished":
        p("  *** SUCCESS! ***")

p(f"\n  Final grappa={ATH.ATHostConnectionGetGrappaSessionId(conn)}")
ATH.ATHostConnectionInvalidate(conn)
ATH.ATHostConnectionRelease(conn)
p("[+] Done — check TV app")
