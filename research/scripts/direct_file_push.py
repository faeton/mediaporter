#!/usr/bin/env python3
"""
BREAKTHROUGH TEST: Skip sync handshake entirely!
third-party tool doesn't use SendSyncRequest or GetGrappaSessionId.
It goes directly: CreateWithLibrary → ReadMessages → SendFileBegin → done.

This test pushes a file directly via ATHostConnection without the Grappa sync handshake.
"""
import ctypes
from ctypes import c_void_p, c_char_p, c_int, c_uint, c_int64, POINTER, byref
import signal, sys, os, struct, time

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
kCFBooleanFalse = c_void_p.in_dll(CF, 'kCFBooleanFalse')
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
CF.CFDataCreate.restype = c_void_p
CF.CFDataCreate.argtypes = [c_void_p, c_void_p, c_int64]
CF.CFShow.restype = None
CF.CFShow.argtypes = [c_void_p]
CF.CFArrayCreateMutable.restype = c_void_p
CF.CFArrayCreateMutable.argtypes = [c_void_p, c_int, c_void_p]
CF.CFArrayAppendValue.restype = None
CF.CFArrayAppendValue.argtypes = [c_void_p, c_void_p]

kCFNumberSInt32Type = 3
kCFNumberSInt64Type = 4

def cfstr(s):
    return CF.CFStringCreateWithCString(kCFAllocatorDefault, s.encode('utf-8'), 0x08000100)
def cfstr_to_str(cf):
    if not cf: return None
    buf = ctypes.create_string_buffer(4096)
    return buf.value.decode('utf-8') if CF.CFStringGetCString(cf, buf, 4096, 0x08000100) else None
def cfnum32(val):
    v = ctypes.c_int32(val)
    return CF.CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, byref(v))
def cfnum64(val):
    v = ctypes.c_int64(val)
    return CF.CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, byref(v))

MD.AMDCreateDeviceList.restype = c_void_p; MD.AMDCreateDeviceList.argtypes = []
MD.AMDeviceConnect.restype = c_int; MD.AMDeviceConnect.argtypes = [c_void_p]
MD.AMDeviceValidatePairing.restype = c_int; MD.AMDeviceValidatePairing.argtypes = [c_void_p]
MD.AMDeviceStartSession.restype = c_int; MD.AMDeviceStartSession.argtypes = [c_void_p]
MD.AMDeviceCopyDeviceIdentifier.restype = c_void_p; MD.AMDeviceCopyDeviceIdentifier.argtypes = [c_void_p]

ATH.ATHostConnectionCreateWithLibrary.restype = c_void_p
ATH.ATHostConnectionCreateWithLibrary.argtypes = [c_void_p, c_void_p, c_uint]
ATH.ATHostConnectionGetGrappaSessionId.restype = c_uint
ATH.ATHostConnectionGetGrappaSessionId.argtypes = [c_void_p]
ATH.ATHostConnectionGetCurrentSessionNumber.restype = c_uint
ATH.ATHostConnectionGetCurrentSessionNumber.argtypes = [c_void_p]
ATH.ATHostConnectionSendHostInfo.restype = c_int
ATH.ATHostConnectionSendHostInfo.argtypes = [c_void_p, c_void_p]
ATH.ATHostConnectionSendFileBegin.restype = c_int
ATH.ATHostConnectionSendFileBegin.argtypes = [c_void_p, c_void_p]
ATH.ATHostConnectionSendFileProgress.restype = c_int
ATH.ATHostConnectionSendFileProgress.argtypes = [c_void_p, c_void_p]
ATH.ATHostConnectionSendAssetCompleted.restype = c_int
ATH.ATHostConnectionSendAssetCompleted.argtypes = [c_void_p, c_void_p, c_void_p, c_void_p]
ATH.ATHostConnectionSendMetadataSyncFinished.restype = c_int
ATH.ATHostConnectionSendMetadataSyncFinished.argtypes = [c_void_p, c_void_p, c_void_p]
ATH.ATHostConnectionSendMessage.restype = c_int
ATH.ATHostConnectionSendMessage.argtypes = [c_void_p, c_void_p]
ATH.ATHostConnectionSendPing.restype = c_int
ATH.ATHostConnectionSendPing.argtypes = [c_void_p]
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


# ── Find test file ────────────────────────────────────────────────────────
test_file = None
for d in ["/Users/faeton/Sites/mediaporter/test_fixtures"]:
    if os.path.exists(d):
        for f in sorted(os.listdir(d)):
            if f.endswith(('.m4v', '.mp4')):
                candidate = os.path.join(d, f)
                if os.path.getsize(candidate) > 1000:
                    test_file = candidate
                    break
    if test_file:
        break

if not test_file:
    p("[-] No test file found. Create one first with: mediaporter test-videos test_fixtures/")
    sys.exit(1)

file_size = os.path.getsize(test_file)
file_name = os.path.basename(test_file)
p(f"[+] Test file: {file_name} ({file_size} bytes)")

# ── Device ────────────────────────────────────────────────────────────────
device_list = MD.AMDCreateDeviceList()
if CF.CFArrayGetCount(device_list) == 0:
    p("[-] No device"); sys.exit(1)
device = CF.CFArrayGetValueAtIndex(device_list, 0)
udid = cfstr_to_str(MD.AMDeviceCopyDeviceIdentifier(device))
p(f"[+] Device: {udid}")

# ── Create ATHostConnection ──────────────────────────────────────────────
p("\n[*] Creating ATHostConnection...")
conn = ATH.ATHostConnectionCreateWithLibrary(cfstr("com.softorino.bigsync"), cfstr(udid), 0)
p(f"[+] conn={hex(conn) if conn else 'NULL'}")

# Read initial messages (drain the queue)
p("[*] Reading initial messages...")
session = 0
for i in range(8):
    msg, name = read_msg(conn, timeout_sec=5)
    if name in ["TIMEOUT", None]:
        p(f"  [{i}] {name or 'NULL'} — done reading")
        break
    session = ATH.ATCFMessageGetSessionNumber(msg)
    p(f"  [{i}] << {name} (session={session})")

# ── Try direct SendFileBegin (third-party tool approach — skip sync!) ───────────────
p(f"\n[*] === DIRECT FILE PUSH (skipping sync handshake) ===")
p(f"[*] Sending FileBegin for {file_name}...")

# Build file info dict — mimicking what third-party tool's fileBegin:type:fileSize:totalSize: does
file_info = CF.CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
    kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks)

# These are guesses based on third-party tool's method signature and ATC protocol
CF.CFDictionarySetValue(file_info, cfstr("Path"), cfstr(f"iTunes_Control/Music/F00/{file_name}"))
CF.CFDictionarySetValue(file_info, cfstr("Location"), cfstr(f"F00/{file_name}"))
CF.CFDictionarySetValue(file_info, cfstr("FileSize"), cfnum64(file_size))
CF.CFDictionarySetValue(file_info, cfstr("TotalSize"), cfnum64(file_size))
CF.CFDictionarySetValue(file_info, cfstr("TransferType"), cfnum32(0))  # 0=media?
CF.CFDictionarySetValue(file_info, cfstr("DataClass"), cfstr("com.apple.Movies"))

err = ATH.ATHostConnectionSendFileBegin(conn, file_info)
p(f"  SendFileBegin: {err} (0x{err & 0xFFFFFFFF:08x})")

# Read response
for i in range(3):
    msg, name = read_msg(conn, timeout_sec=5)
    if name in ["TIMEOUT", None]:
        p(f"  [R{i}] {name or 'NULL'}")
        break
    p(f"  [R{i}] << {name}")
    if name == "SyncFailed":
        ec = ATH.ATCFMessageGetParam(msg, cfstr("ErrorCode"))
        if ec:
            p(f"       ErrorCode present")
            CF.CFShow(ec)
        break

# ── Also try via raw ATCFMessage (how third-party tool uses SendMessage) ────────────
p(f"\n[*] === Try via raw ATCFMessage ===")

# Create a FileBegin message manually
fb_params = CF.CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
    kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks)
CF.CFDictionarySetValue(fb_params, cfstr("Path"), cfstr(f"iTunes_Control/Music/F00/{file_name}"))
CF.CFDictionarySetValue(fb_params, cfstr("FileSize"), cfnum64(file_size))
CF.CFDictionarySetValue(fb_params, cfstr("TotalSize"), cfnum64(file_size))

# third-party tool's method: fileBegin:type:fileSize:totalSize:
# This suggests the SendFileBegin dict needs type, fileSize, totalSize
CF.CFDictionarySetValue(fb_params, cfstr("Type"), cfstr("Movie"))

fb_msg = ATH.ATCFMessageCreate(session, cfstr("FileBegin"), fb_params)
if fb_msg:
    err = ATH.ATHostConnectionSendMessage(conn, fb_msg)
    p(f"  SendMessage(FileBegin): {err} (0x{err & 0xFFFFFFFF:08x})")

    for i in range(3):
        msg, name = read_msg(conn, timeout_sec=5)
        if name in ["TIMEOUT", None]:
            p(f"  [R{i}] {name or 'NULL'}")
            break
        p(f"  [R{i}] << {name}")

# ── Try FinishedSyncingMetadata (what third-party tool's string references show) ────
p(f"\n[*] === Try FinishedSyncingMetadata ===")

fsm_params = CF.CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
    kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks)

sync_types = CF.CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
    kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks)
CF.CFDictionarySetValue(sync_types, cfstr("com.apple.Movies"), kCFBooleanTrue)
CF.CFDictionarySetValue(fsm_params, cfstr("SyncTypes"), sync_types)

err = ATH.ATHostConnectionSendMetadataSyncFinished(conn, fsm_params, None)
p(f"  SendMetadataSyncFinished: {err} (0x{err & 0xFFFFFFFF:08x})")

for i in range(3):
    msg, name = read_msg(conn, timeout_sec=5)
    if name in ["TIMEOUT", None]:
        p(f"  [R{i}] {name or 'NULL'}")
        break
    p(f"  [R{i}] << {name}")

# ── Cleanup ───────────────────────────────────────────────────────────────
ATH.ATHostConnectionInvalidate(conn)
ATH.ATHostConnectionRelease(conn)
p("\n[+] Done")
