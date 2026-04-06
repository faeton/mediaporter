#!/usr/bin/env python3
"""
PoC v4: Minimal, stdout-flushed test.
"""
import ctypes
from ctypes import c_void_p, c_char_p, c_int, c_uint, POINTER, byref
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

def cfstr_to_str(cfstring):
    if not cfstring: return None
    buf = ctypes.create_string_buffer(4096)
    if CF.CFStringGetCString(cfstring, buf, 4096, 0x08000100):
        return buf.value.decode('utf-8')
    return None

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
MD.AMDeviceSecureStartService.restype = c_int
MD.AMDeviceSecureStartService.argtypes = [c_void_p, c_void_p, c_void_p, POINTER(c_void_p)]
MD.AMDeviceStartService.restype = c_int
MD.AMDeviceStartService.argtypes = [c_void_p, c_void_p, POINTER(c_void_p), c_void_p]
MD.AMDServiceConnectionGetSocket.restype = c_int
MD.AMDServiceConnectionGetSocket.argtypes = [c_void_p]

ATH.ATHostConnectionCreateWithLibrary.restype = c_void_p
ATH.ATHostConnectionCreateWithLibrary.argtypes = [c_void_p, c_void_p, c_uint]
ATH.ATHostConnectionCreate.restype = c_void_p
ATH.ATHostConnectionCreate.argtypes = [c_void_p, c_void_p, c_uint]
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


p("[+] Frameworks loaded")

# Device
device_list = MD.AMDCreateDeviceList()
count = CF.CFArrayGetCount(device_list)
p(f"[+] Devices: {count}")
if count == 0:
    p("[-] No device")
    sys.exit(1)

device = CF.CFArrayGetValueAtIndex(device_list, 0)
udid = cfstr_to_str(MD.AMDeviceCopyDeviceIdentifier(device))
p(f"[+] UDID: {udid}")

e1 = MD.AMDeviceConnect(device)
e2 = MD.AMDeviceValidatePairing(device)
e3 = MD.AMDeviceStartSession(device)
p(f"[+] Connect={e1}, Validate={e2}, Session={e3}")

name = cfstr_to_str(MD.AMDeviceCopyValue(device, None, cfstr("DeviceName")))
ios = cfstr_to_str(MD.AMDeviceCopyValue(device, None, cfstr("ProductVersion")))
p(f"[+] {name} — iOS {ios}")

# ── Test: AMDeviceSecureStartService for ATC ──────────────────────────────
p("\n=== TEST: AMDeviceSecureStartService ===")
for svc in ["com.apple.atc", "com.apple.atc2"]:
    svc_conn = c_void_p()
    err = MD.AMDeviceSecureStartService(device, cfstr(svc), None, byref(svc_conn))
    if svc_conn.value:
        sock = MD.AMDServiceConnectionGetSocket(svc_conn)
        p(f"  {svc}: err={err}, sock={sock}")
    else:
        p(f"  {svc}: err={err}, NULL")

# ── Test: ATHostConnection — read all initial messages ────────────────────
p("\n=== TEST: ATHostConnection full flow ===")
conn = ATH.ATHostConnectionCreateWithLibrary(cfstr("com.apple.iTunes"), cfstr(udid), 0)
p(f"  conn={hex(conn) if conn else 'NULL'}")
p(f"  grappa_init={ATH.ATHostConnectionGetGrappaSessionId(conn)}")

# Read ALL messages until timeout
p("  Reading messages from device:")
all_msgs = []
for i in range(15):
    msg, name = read_msg(conn, timeout_sec=3)
    if name == "TIMEOUT":
        p(f"  [{i}] TIMEOUT — no more messages")
        break
    if name is None:
        p(f"  [{i}] NULL")
        break
    p(f"  [{i}] << {name} (session={ATH.ATCFMessageGetSessionNumber(msg)})")
    all_msgs.append(name)

    # Check grappa after each message
    g = ATH.ATHostConnectionGetGrappaSessionId(conn)
    if g != 0:
        p(f"       *** GRAPPA SESSION: {g}")

p(f"\n  Messages received: {all_msgs}")
p(f"  Final grappa: {ATH.ATHostConnectionGetGrappaSessionId(conn)}")
p(f"  Final session: {ATH.ATHostConnectionGetCurrentSessionNumber(conn)}")

# Now try sending
p("\n  Sending HostInfo...")
host_info = CF.CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
    kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks)
CF.CFDictionarySetValue(host_info, cfstr("HostName"), cfstr("mediaporter"))
CF.CFDictionarySetValue(host_info, cfstr("HostID"), cfstr("com.apple.iTunes"))
CF.CFDictionarySetValue(host_info, cfstr("Version"), cfstr("12.13.2.3"))
err = ATH.ATHostConnectionSendHostInfo(conn, host_info)
p(f"  SendHostInfo: {err} (0x{err & 0xFFFFFFFF:08x})")

p("  Sending PowerAssertion...")
err = ATH.ATHostConnectionSendPowerAssertion(conn, kCFBooleanTrue)
p(f"  SendPowerAssertion: {err} (0x{err & 0xFFFFFFFF:08x})")

p("  Sending SyncRequest...")
dc = CF.CFArrayCreateMutable(kCFAllocatorDefault, 0, kCFTypeArrayCallBacks)
CF.CFArrayAppendValue(dc, cfstr("com.apple.media"))
anchors = CF.CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
    kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks)
err = ATH.ATHostConnectionSendSyncRequest(conn, dc, anchors, None)
p(f"  SendSyncRequest: {err} (0x{err & 0xFFFFFFFF:08x})")

# Read responses
p("  Reading responses:")
for i in range(5):
    msg, name = read_msg(conn, timeout_sec=3)
    if name == "TIMEOUT":
        p(f"  [R{i}] TIMEOUT")
        break
    if name is None:
        p(f"  [R{i}] NULL")
        break
    p(f"  [R{i}] << {name}")
    if name == "SyncFailed":
        ec = ATH.ATCFMessageGetParam(msg, cfstr("ErrorCode"))
        if ec:
            p(f"       ErrorCode present: {hex(ec)}")
        break

ATH.ATHostConnectionInvalidate(conn)
ATH.ATHostConnectionRelease(conn)
p("\n[+] Done")
