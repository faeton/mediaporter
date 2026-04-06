#!/usr/bin/env python3
"""
third-party tool approach v2: Use SendMessage for everything (third-party tool uses SendMessage, not the typed Send* functions).
Also try to understand the internal state machine better.

From third-party tool strings:
- fileBegin:type:fileSize:totalSize:   — their ObjC wrapper
- assetCompleted:location:type:        — their ObjC wrapper
- addTrack2Library                     — add to library
- /iTunes_Control/Sync/Media/%@        — sync media path

The assertion "dataclass" in SendFileBegin means the connection needs
a data class set. Maybe SendHostInfo or a previous message sets this.
third-party tool imports SendHostInfo — maybe that's what sets the data class.
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
CF.CFArrayGetCount.restype = c_int
CF.CFArrayGetCount.argtypes = [c_void_p]
CF.CFArrayGetValueAtIndex.restype = c_void_p
CF.CFArrayGetValueAtIndex.argtypes = [c_void_p, c_int]
CF.CFNumberCreate.restype = c_void_p
CF.CFNumberCreate.argtypes = [c_void_p, c_int, c_void_p]
CF.CFShow.restype = None
CF.CFShow.argtypes = [c_void_p]
CF.CFArrayCreateMutable.restype = c_void_p
CF.CFArrayCreateMutable.argtypes = [c_void_p, c_int, c_void_p]
CF.CFArrayAppendValue.restype = None
CF.CFArrayAppendValue.argtypes = [c_void_p, c_void_p]
CF.CFCopyDescription.restype = c_void_p
CF.CFCopyDescription.argtypes = [c_void_p]

def cfstr(s):
    return CF.CFStringCreateWithCString(kCFAllocatorDefault, s.encode('utf-8'), 0x08000100)
def cfstr_to_str(cf):
    if not cf: return None
    buf = ctypes.create_string_buffer(4096)
    return buf.value.decode('utf-8') if CF.CFStringGetCString(cf, buf, 4096, 0x08000100) else None
def cfnum32(val):
    v = ctypes.c_int32(val)
    return CF.CFNumberCreate(kCFAllocatorDefault, 3, byref(v))
def cfnum64(val):
    v = ctypes.c_int64(val)
    return CF.CFNumberCreate(kCFAllocatorDefault, 4, byref(v))
def cf_desc(obj):
    if not obj: return "NULL"
    d = CF.CFCopyDescription(obj)
    s = cfstr_to_str(d) if d else "?"
    return s

MD.AMDCreateDeviceList.restype = c_void_p; MD.AMDCreateDeviceList.argtypes = []
MD.AMDeviceCopyDeviceIdentifier.restype = c_void_p; MD.AMDeviceCopyDeviceIdentifier.argtypes = [c_void_p]

ATH.ATHostConnectionCreateWithLibrary.restype = c_void_p
ATH.ATHostConnectionCreateWithLibrary.argtypes = [c_void_p, c_void_p, c_uint]
ATH.ATHostConnectionGetCurrentSessionNumber.restype = c_uint
ATH.ATHostConnectionGetCurrentSessionNumber.argtypes = [c_void_p]
ATH.ATHostConnectionSendHostInfo.restype = c_int
ATH.ATHostConnectionSendHostInfo.argtypes = [c_void_p, c_void_p]
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

def send_raw_msg(conn, session, command, params):
    """Send a raw ATCFMessage via SendMessage."""
    msg = ATH.ATCFMessageCreate(session, cfstr(command), params)
    if not msg:
        p(f"  ATCFMessageCreate({command}) returned NULL")
        return -1
    err = ATH.ATHostConnectionSendMessage(conn, msg)
    p(f"  >> {command}: err={err} (0x{err & 0xFFFFFFFF:08x})")
    return err


# ── Setup ─────────────────────────────────────────────────────────────────
test_file = None
for d in ["/Users/faeton/Sites/mediaporter/test_fixtures"]:
    if os.path.exists(d):
        for f in sorted(os.listdir(d)):
            if f.endswith(('.m4v', '.mp4')):
                candidate = os.path.join(d, f)
                if os.path.getsize(candidate) > 1000:
                    test_file = candidate
                    break
if not test_file:
    p("[-] No test file"); sys.exit(1)

file_size = os.path.getsize(test_file)
file_name = os.path.basename(test_file)
p(f"[+] File: {file_name} ({file_size} bytes)")

device_list = MD.AMDCreateDeviceList()
device = CF.CFArrayGetValueAtIndex(device_list, 0)
udid = cfstr_to_str(MD.AMDeviceCopyDeviceIdentifier(device))
p(f"[+] Device: {udid}")

# ── Connect ───────────────────────────────────────────────────────────────
conn = ATH.ATHostConnectionCreateWithLibrary(cfstr("com.softorino.bigsync"), cfstr(udid), 0)
p(f"[+] conn={hex(conn) if conn else 'NULL'}")

# Read initial messages
p("\n[*] Reading initial messages...")
session = 0
for i in range(5):
    msg, name = read_msg(conn, timeout_sec=5)
    if name in ["TIMEOUT", None]:
        break
    session = ATH.ATCFMessageGetSessionNumber(msg)
    p(f"  [{i}] << {name} (session={session})")

# ── Send HostInfo first (third-party tool imports this) ──────────────────────────────
p("\n[*] Sending HostInfo via raw message...")
hi_params = CF.CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
    kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks)
CF.CFDictionarySetValue(hi_params, cfstr("HostName"), cfstr("third-party sync tool"))
CF.CFDictionarySetValue(hi_params, cfstr("HostID"), cfstr("com.softorino.bigsync"))
CF.CFDictionarySetValue(hi_params, cfstr("Version"), cfstr("12.13.2.3"))
send_raw_msg(conn, session, "HostInfo", hi_params)

# ── Try RequestingSync via raw message ────────────────────────────────────
p("\n[*] Sending RequestingSync via raw message...")
rs_params = CF.CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
    kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks)
dc = CF.CFArrayCreateMutable(kCFAllocatorDefault, 0, kCFTypeArrayCallBacks)
CF.CFArrayAppendValue(dc, cfstr("com.apple.media"))
CF.CFDictionarySetValue(rs_params, cfstr("DataClasses"), dc)
send_raw_msg(conn, session, "RequestingSync", rs_params)

# Read response
for i in range(3):
    msg, name = read_msg(conn, timeout_sec=5)
    if name in ["TIMEOUT", None]:
        p(f"  [{i}] {name or 'NULL'}")
        break
    p(f"  [{i}] << {name}")
    if name == "SyncFailed":
        ec = ATH.ATCFMessageGetParam(msg, cfstr("ErrorCode"))
        if ec: CF.CFShow(ec)
        rv = ATH.ATCFMessageGetParam(msg, cfstr("RequiredVersion"))
        if rv: CF.CFShow(rv)
    elif name == "SyncAllowed":
        # Try BeginSync
        p("\n  Got SyncAllowed again. Sending BeginSync...")
        bs_params = CF.CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
            kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks)
        st = CF.CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
            kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks)
        CF.CFDictionarySetValue(st, cfstr("com.apple.Movies"), kCFBooleanTrue)
        CF.CFDictionarySetValue(bs_params, cfstr("SyncTypes"), st)
        send_raw_msg(conn, session, "BeginSync", bs_params)

        for j in range(3):
            msg2, name2 = read_msg(conn, timeout_sec=5)
            if name2 in ["TIMEOUT", None]:
                p(f"    [BS{j}] {name2 or 'NULL'}")
                break
            p(f"    [BS{j}] << {name2}")
            if name2 == "ReadyForSync":
                p("    *** ReadyForSync! Can now send files!")
            if name2 == "SyncFailed":
                ec2 = ATH.ATCFMessageGetParam(msg2, cfstr("ErrorCode"))
                if ec2: CF.CFShow(ec2)
                break

# ── Try direct FileBegin via raw message (skip sync entirely) ─────────────
p("\n[*] Sending FileBegin via raw message (no sync handshake)...")
fb_params = CF.CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
    kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks)
CF.CFDictionarySetValue(fb_params, cfstr("Path"), cfstr(f"iTunes_Control/Music/F00/{file_name}"))
CF.CFDictionarySetValue(fb_params, cfstr("FileSize"), cfnum64(file_size))
CF.CFDictionarySetValue(fb_params, cfstr("TotalSize"), cfnum64(file_size))
CF.CFDictionarySetValue(fb_params, cfstr("Type"), cfstr("Movie"))
CF.CFDictionarySetValue(fb_params, cfstr("MediaType"), cfnum32(8192))
CF.CFDictionarySetValue(fb_params, cfstr("MediaKind"), cfnum32(1024))
send_raw_msg(conn, session, "FileBegin", fb_params)

for i in range(3):
    msg, name = read_msg(conn, timeout_sec=5)
    if name in ["TIMEOUT", None]:
        p(f"  [{i}] {name or 'NULL'}")
        break
    p(f"  [{i}] << {name}")

# ── Try FinishedSyncingMetadata ───────────────────────────────────────────
p("\n[*] Sending FinishedSyncingMetadata via raw message...")
fsm_params = CF.CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
    kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks)
st2 = CF.CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
    kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks)
CF.CFDictionarySetValue(st2, cfstr("com.apple.Movies"), kCFBooleanTrue)
CF.CFDictionarySetValue(fsm_params, cfstr("SyncTypes"), st2)
CF.CFDictionarySetValue(fsm_params, cfstr("Anchors"), CF.CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
    kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks))
send_raw_msg(conn, session, "FinishedSyncingMetadata", fsm_params)

for i in range(3):
    msg, name = read_msg(conn, timeout_sec=5)
    if name in ["TIMEOUT", None]:
        p(f"  [{i}] {name or 'NULL'}")
        break
    p(f"  [{i}] << {name}")

ATH.ATHostConnectionInvalidate(conn)
ATH.ATHostConnectionRelease(conn)
p("\n[+] Done")
