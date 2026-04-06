#!/usr/bin/env python3
"""
Test AirTrafficHost under Rosetta (x86_64) using system Python.
third-party tool is x86_64 and works — maybe CoreFP x86_64 path handles FairPlay differently.
"""
import ctypes
from ctypes import c_void_p, c_char_p, c_int, c_uint, POINTER, byref
import struct, plistlib, signal, sys, platform

def p(msg):
    print(msg, flush=True)

p(f"[*] Architecture: {platform.machine()}")
p(f"[*] Python: {sys.executable} {sys.version}")

def timeout_handler(signum, frame):
    raise TimeoutError()
signal.signal(signal.SIGALRM, timeout_handler)

CF = ctypes.cdll.LoadLibrary('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
MD = ctypes.cdll.LoadLibrary('/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice')
ATH = ctypes.cdll.LoadLibrary('/System/Library/PrivateFrameworks/AirTrafficHost.framework/AirTrafficHost')
p("[+] Frameworks loaded")

kCFAllocatorDefault = c_void_p.in_dll(CF, 'kCFAllocatorDefault')
kCFBooleanTrue = c_void_p.in_dll(CF, 'kCFBooleanTrue')
kCFTypeDictionaryKeyCallBacks = c_void_p.in_dll(CF, 'kCFTypeDictionaryKeyCallBacks')
kCFTypeDictionaryValueCallBacks = c_void_p.in_dll(CF, 'kCFTypeDictionaryValueCallBacks')
kCFTypeArrayCallBacks = c_void_p.in_dll(CF, 'kCFTypeArrayCallBacks')

CF.CFStringCreateWithCString.restype = c_void_p
CF.CFStringCreateWithCString.argtypes = [c_void_p, c_char_p, c_uint]
CF.CFStringGetCString.restype = ctypes.c_bool
CF.CFStringGetCString.argtypes = [c_void_p, c_char_p, c_int, c_uint]
CF.CFArrayGetCount.restype = c_int
CF.CFArrayGetCount.argtypes = [c_void_p]
CF.CFArrayGetValueAtIndex.restype = c_void_p
CF.CFArrayGetValueAtIndex.argtypes = [c_void_p, c_int]
CF.CFDictionaryCreateMutable.restype = c_void_p
CF.CFDictionaryCreateMutable.argtypes = [c_void_p, c_int, c_void_p, c_void_p]
CF.CFDictionarySetValue.restype = None
CF.CFDictionarySetValue.argtypes = [c_void_p, c_void_p, c_void_p]
CF.CFArrayCreateMutable.restype = c_void_p
CF.CFArrayCreateMutable.argtypes = [c_void_p, c_int, c_void_p]
CF.CFArrayAppendValue.restype = None
CF.CFArrayAppendValue.argtypes = [c_void_p, c_void_p]

def cfstr(s):
    return CF.CFStringCreateWithCString(kCFAllocatorDefault, s.encode('utf-8'), 0x08000100)
def cfstr_to_str(cf):
    if not cf: return None
    buf = ctypes.create_string_buffer(4096)
    return buf.value.decode('utf-8') if CF.CFStringGetCString(cf, buf, 4096, 0x08000100) else None

MD.AMDCreateDeviceList.restype = c_void_p
MD.AMDCreateDeviceList.argtypes = []
MD.AMDeviceConnect.restype = c_int
MD.AMDeviceConnect.argtypes = [c_void_p]
MD.AMDeviceValidatePairing.restype = c_int
MD.AMDeviceValidatePairing.argtypes = [c_void_p]
MD.AMDeviceStartSession.restype = c_int
MD.AMDeviceStartSession.argtypes = [c_void_p]
MD.AMDeviceCopyDeviceIdentifier.restype = c_void_p
MD.AMDeviceCopyDeviceIdentifier.argtypes = [c_void_p]
MD.AMDeviceCopyValue.restype = c_void_p
MD.AMDeviceCopyValue.argtypes = [c_void_p, c_void_p, c_void_p]

ATH.ATHostConnectionCreateWithLibrary.restype = c_void_p
ATH.ATHostConnectionCreateWithLibrary.argtypes = [c_void_p, c_void_p, c_uint]
ATH.ATHostConnectionGetGrappaSessionId.restype = c_uint
ATH.ATHostConnectionGetGrappaSessionId.argtypes = [c_void_p]
ATH.ATHostConnectionGetCurrentSessionNumber.restype = c_uint
ATH.ATHostConnectionGetCurrentSessionNumber.argtypes = [c_void_p]
ATH.ATHostConnectionSendHostInfo.restype = c_int
ATH.ATHostConnectionSendHostInfo.argtypes = [c_void_p, c_void_p]
ATH.ATHostConnectionSendPowerAssertion.restype = c_int
ATH.ATHostConnectionSendPowerAssertion.argtypes = [c_void_p, c_void_p]
ATH.ATHostConnectionSendSyncRequest.restype = c_int
ATH.ATHostConnectionSendSyncRequest.argtypes = [c_void_p, c_void_p, c_void_p, c_void_p]
ATH.ATHostConnectionReadMessage.restype = c_void_p
ATH.ATHostConnectionReadMessage.argtypes = [c_void_p]
ATH.ATHostConnectionSendMessage.restype = c_int
ATH.ATHostConnectionSendMessage.argtypes = [c_void_p, c_void_p]
ATH.ATHostConnectionSendPing.restype = c_int
ATH.ATHostConnectionSendPing.argtypes = [c_void_p]
ATH.ATHostConnectionInvalidate.restype = c_int
ATH.ATHostConnectionInvalidate.argtypes = [c_void_p]
ATH.ATHostConnectionRelease.restype = None
ATH.ATHostConnectionRelease.argtypes = [c_void_p]

ATH.ATCFMessageGetName.restype = c_void_p
ATH.ATCFMessageGetName.argtypes = [c_void_p]
ATH.ATCFMessageGetParam.restype = c_void_p
ATH.ATCFMessageGetParam.argtypes = [c_void_p, c_void_p]
ATH.ATCFMessageGetSessionNumber.restype = c_uint
ATH.ATCFMessageGetSessionNumber.argtypes = [c_void_p]
ATH.ATCFMessageCreate.restype = c_void_p
ATH.ATCFMessageCreate.argtypes = [c_uint, c_void_p, c_void_p]

def read_msg(conn, timeout_sec=5):
    signal.alarm(timeout_sec)
    try:
        msg = ATH.ATHostConnectionReadMessage(conn)
        signal.alarm(0)
        if not msg: return None, None
        name = cfstr_to_str(ATH.ATCFMessageGetName(msg))
        session = ATH.ATCFMessageGetSessionNumber(msg)
        return msg, name
    except TimeoutError:
        signal.alarm(0)
        return None, "TIMEOUT"

# ── Device ────────────────────────────────────────────────────────────────
device_list = MD.AMDCreateDeviceList()
count = CF.CFArrayGetCount(device_list)
p(f"[+] Devices: {count}")
if count == 0:
    p("[-] No device"); sys.exit(1)

device = CF.CFArrayGetValueAtIndex(device_list, 0)
udid = cfstr_to_str(MD.AMDeviceCopyDeviceIdentifier(device))
p(f"[+] UDID: {udid}")

e1 = MD.AMDeviceConnect(device)
e2 = MD.AMDeviceValidatePairing(device)
e3 = MD.AMDeviceStartSession(device)
p(f"[+] Connect={e1} Validate={e2} Session={e3}")

name = cfstr_to_str(MD.AMDeviceCopyValue(device, None, cfstr("DeviceName")))
p(f"[+] {name}")

# ── ATHostConnection ──────────────────────────────────────────────────────
p("\n=== ATHostConnection (matching third-party tool's approach) ===")

# Use a library ID like third-party tool does
conn = ATH.ATHostConnectionCreateWithLibrary(cfstr("com.softorino.bigsync"), cfstr(udid), 0)
p(f"  conn={hex(conn) if conn else 'NULL'}")
p(f"  grappa_init={ATH.ATHostConnectionGetGrappaSessionId(conn)}")
p(f"  session_init={ATH.ATHostConnectionGetCurrentSessionNumber(conn)}")

# Read initial messages
p("\n  Reading messages:")
all_msgs = []
for i in range(10):
    msg, name = read_msg(conn, timeout_sec=5)
    if name == "TIMEOUT":
        p(f"  [{i}] TIMEOUT")
        break
    if name is None:
        p(f"  [{i}] NULL")
        break
    p(f"  [{i}] << {name}")
    all_msgs.append(name)

    g = ATH.ATHostConnectionGetGrappaSessionId(conn)
    s = ATH.ATHostConnectionGetCurrentSessionNumber(conn)
    p(f"       grappa={g} session={s}")

    if name == "SyncAllowed":
        break

# Send HostInfo (third-party tool uses this)
p("\n  Sending HostInfo...")
host_info = CF.CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
    kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks)
CF.CFDictionarySetValue(host_info, cfstr("HostName"), cfstr("third-party sync tool"))
CF.CFDictionarySetValue(host_info, cfstr("HostID"), cfstr("com.softorino.bigsync"))
CF.CFDictionarySetValue(host_info, cfstr("Version"), cfstr("12.13.2.3"))
err = ATH.ATHostConnectionSendHostInfo(conn, host_info)
p(f"  SendHostInfo: {err} (0x{err & 0xFFFFFFFF:08x})")

# Send Ping (third-party tool uses this)
p("  Sending Ping...")
err = ATH.ATHostConnectionSendPing(conn)
p(f"  SendPing: {err} (0x{err & 0xFFFFFFFF:08x})")

# Try SendSyncRequest via SendMessage (how third-party tool does it — using SendMessage not SendSyncRequest)
p("\n  Sending RequestingSync via ATCFMessage...")
params = CF.CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
    kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks)

dc = CF.CFArrayCreateMutable(kCFAllocatorDefault, 0, kCFTypeArrayCallBacks)
CF.CFArrayAppendValue(dc, cfstr("com.apple.media"))
CF.CFDictionarySetValue(params, cfstr("DataClasses"), dc)

session_num = ATH.ATHostConnectionGetCurrentSessionNumber(conn)
msg = ATH.ATCFMessageCreate(session_num, cfstr("RequestingSync"), params)
if msg:
    err = ATH.ATHostConnectionSendMessage(conn, msg)
    p(f"  SendMessage(RequestingSync): {err} (0x{err & 0xFFFFFFFF:08x})")
else:
    p("  ATCFMessageCreate returned NULL")

# Read response
p("\n  Reading responses:")
for i in range(5):
    rmsg, rname = read_msg(conn, timeout_sec=5)
    if rname == "TIMEOUT":
        p(f"  [R{i}] TIMEOUT")
        break
    if rname is None:
        p(f"  [R{i}] NULL")
        break
    p(f"  [R{i}] << {rname}")

    if rname == "SyncFailed":
        ec = ATH.ATCFMessageGetParam(rmsg, cfstr("ErrorCode"))
        rv = ATH.ATCFMessageGetParam(rmsg, cfstr("RequiredVersion"))
        p(f"       ErrorCode ptr: {hex(ec) if ec else 'NULL'}")
        p(f"       RequiredVersion ptr: {hex(rv) if rv else 'NULL'}")
        break
    if rname in ["ReadyForSync", "SyncAllowed"]:
        p(f"       *** {rname}! ***")

# Final state
g = ATH.ATHostConnectionGetGrappaSessionId(conn)
s = ATH.ATHostConnectionGetCurrentSessionNumber(conn)
p(f"\n  Final: grappa={g} session={s}")

ATH.ATHostConnectionInvalidate(conn)
ATH.ATHostConnectionRelease(conn)
p("\n[+] Done")
