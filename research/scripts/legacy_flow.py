#!/usr/bin/env python3
"""
Replicate third-party tool's exact flow:
1. AMDeviceNotificationSubscribe (callback-based device detection)
2. ATHostConnectionCreateWithLibrary (NO prior AMDeviceConnect)
3. ReadMessage loop
4. SendHostInfo/SendMessage/SendFileBegin etc.

Key hypothesis: maybe calling AMDeviceConnect/StartSession BEFORE
ATHostConnectionCreateWithLibrary steals the lockdown session
and prevents the framework from doing Grappa.
"""
import ctypes
from ctypes import c_void_p, c_char_p, c_int, c_uint, c_long, CFUNCTYPE, POINTER, byref, Structure, cast
import signal, sys, time, platform, struct

def p(msg):
    print(msg, flush=True)

p(f"[*] Arch: {platform.machine()}")

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
kCFRunLoopDefaultMode = c_void_p.in_dll(CF, 'kCFRunLoopDefaultMode')

CF.CFStringCreateWithCString.restype = c_void_p
CF.CFStringCreateWithCString.argtypes = [c_void_p, c_char_p, c_uint]
CF.CFStringGetCString.restype = ctypes.c_bool
CF.CFStringGetCString.argtypes = [c_void_p, c_char_p, c_int, c_uint]
CF.CFRunLoopRunInMode.restype = c_int
CF.CFRunLoopRunInMode.argtypes = [c_void_p, ctypes.c_double, ctypes.c_bool]
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

# Device notification callback
# struct am_device_notification_callback_info { am_device_t device; uint msg; }
AMDeviceNotificationCallback = CFUNCTYPE(None, c_void_p, c_void_p)

MD.AMDeviceNotificationSubscribe.restype = c_int
MD.AMDeviceNotificationSubscribe.argtypes = [AMDeviceNotificationCallback, c_uint, c_uint, c_void_p, POINTER(c_void_p)]
MD.AMDeviceConnect.restype = c_int
MD.AMDeviceConnect.argtypes = [c_void_p]
MD.AMDeviceIsPaired.restype = c_int
MD.AMDeviceIsPaired.argtypes = [c_void_p]
MD.AMDeviceValidatePairing.restype = c_int
MD.AMDeviceValidatePairing.argtypes = [c_void_p]
MD.AMDeviceStartSession.restype = c_int
MD.AMDeviceStartSession.argtypes = [c_void_p]
MD.AMDeviceStopSession.restype = c_int
MD.AMDeviceStopSession.argtypes = [c_void_p]
MD.AMDeviceDisconnect.restype = c_int
MD.AMDeviceDisconnect.argtypes = [c_void_p]
MD.AMDeviceCopyDeviceIdentifier.restype = c_void_p
MD.AMDeviceCopyDeviceIdentifier.argtypes = [c_void_p]
MD.AMDeviceCopyValue.restype = c_void_p
MD.AMDeviceCopyValue.argtypes = [c_void_p, c_void_p, c_void_p]
MD.AMDeviceGetInterfaceType.restype = c_int
MD.AMDeviceGetInterfaceType.argtypes = [c_void_p]
MD.AMDeviceRetain.restype = c_void_p
MD.AMDeviceRetain.argtypes = [c_void_p]

ATH.ATHostConnectionCreateWithLibrary.restype = c_void_p
ATH.ATHostConnectionCreateWithLibrary.argtypes = [c_void_p, c_void_p, c_uint]
ATH.ATHostConnectionGetGrappaSessionId.restype = c_uint
ATH.ATHostConnectionGetGrappaSessionId.argtypes = [c_void_p]
ATH.ATHostConnectionGetCurrentSessionNumber.restype = c_uint
ATH.ATHostConnectionGetCurrentSessionNumber.argtypes = [c_void_p]
ATH.ATHostConnectionSendHostInfo.restype = c_int
ATH.ATHostConnectionSendHostInfo.argtypes = [c_void_p, c_void_p]
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

CF.CFShow.restype = None
CF.CFShow.argtypes = [c_void_p]

def read_msg(conn, timeout_sec=8):
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


# ══════════════════════════════════════════════════════════════════════════
# APPROACH 1: Use AMDeviceNotificationSubscribe (like third-party tool)
# NO AMDeviceConnect/StartSession before ATHostConnection
# ══════════════════════════════════════════════════════════════════════════
p("\n=== APPROACH 1: Notification-based, NO pre-session ===")

found_device = [None]
found_udid = [None]

@AMDeviceNotificationCallback
def device_callback(info_ptr, user_data):
    # The info struct has device as first field, msg_type as second
    device = cast(info_ptr, POINTER(c_void_p))[0]
    msg_type_ptr = cast(info_ptr, POINTER(c_void_p))[1]

    # msg_type 1 = connected
    if device and not found_device[0]:
        MD.AMDeviceRetain(device)
        udid_cf = MD.AMDeviceCopyDeviceIdentifier(device)
        udid = cfstr_to_str(udid_cf)
        p(f"  [callback] Device found: {udid}")
        found_device[0] = device
        found_udid[0] = udid

notification = c_void_p()
err = MD.AMDeviceNotificationSubscribe(device_callback, 0, 0, None, byref(notification))
p(f"  NotificationSubscribe: {err}")

# Spin run loop to get callbacks
for _ in range(50):  # 5 seconds
    CF.CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, False)
    if found_device[0]:
        break

if not found_device[0]:
    p("  No device found via notification. Exiting.")
    sys.exit(1)

device = found_device[0]
udid = found_udid[0]
p(f"[+] Using device: {udid}")

# DO NOT call AMDeviceConnect/StartSession — let ATHostConnection handle it
p("\n  Creating ATHostConnection WITHOUT prior AMDevice session...")
conn = ATH.ATHostConnectionCreateWithLibrary(cfstr("com.softorino.bigsync"), cfstr(udid), 0)
p(f"  conn={hex(conn) if conn else 'NULL'}")
g = ATH.ATHostConnectionGetGrappaSessionId(conn)
s = ATH.ATHostConnectionGetCurrentSessionNumber(conn)
p(f"  grappa={g} session={s}")

# Read messages
p("\n  Reading messages:")
for i in range(8):
    msg, name = read_msg(conn, timeout_sec=5)
    if name in ["TIMEOUT", None]:
        p(f"  [{i}] {name or 'NULL'}")
        break
    g = ATH.ATHostConnectionGetGrappaSessionId(conn)
    p(f"  [{i}] << {name} (grappa={g})")

    if name == "SyncAllowed":
        # Try sending HostInfo
        hi = CF.CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
            kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks)
        CF.CFDictionarySetValue(hi, cfstr("HostName"), cfstr("third-party sync tool"))
        CF.CFDictionarySetValue(hi, cfstr("HostID"), cfstr("com.softorino.bigsync"))
        CF.CFDictionarySetValue(hi, cfstr("Version"), cfstr("12.13.2.3"))
        err = ATH.ATHostConnectionSendHostInfo(conn, hi)
        p(f"       SendHostInfo: {err} (0x{err & 0xFFFFFFFF:08x})")

        # Try ping
        err = ATH.ATHostConnectionSendPing(conn)
        p(f"       SendPing: {err} (0x{err & 0xFFFFFFFF:08x})")

ATH.ATHostConnectionInvalidate(conn)
ATH.ATHostConnectionRelease(conn)

# ══════════════════════════════════════════════════════════════════════════
# APPROACH 2: Like third-party tool — AMDeviceConnect first, but StopSession before ATHost
# ══════════════════════════════════════════════════════════════════════════
p("\n\n=== APPROACH 2: Connect + pair + stop session, THEN ATHostConnection ===")

e1 = MD.AMDeviceConnect(device)
e2 = MD.AMDeviceIsPaired(device)
e3 = MD.AMDeviceValidatePairing(device)
e4 = MD.AMDeviceStartSession(device)
p(f"  Connect={e1} Paired={e2} Validate={e3} Session={e4}")

# Get interface type (like third-party tool does)
itype = MD.AMDeviceGetInterfaceType(device)
p(f"  InterfaceType: {itype}")  # 1=USB, 2=WiFi

# Now STOP the session before creating ATHostConnection
e5 = MD.AMDeviceStopSession(device)
e6 = MD.AMDeviceDisconnect(device)
p(f"  StopSession={e5} Disconnect={e6}")

p("\n  Creating ATHostConnection after disconnect...")
conn2 = ATH.ATHostConnectionCreateWithLibrary(cfstr("com.softorino.bigsync"), cfstr(udid), 0)
p(f"  conn={hex(conn2) if conn2 else 'NULL'}")
g = ATH.ATHostConnectionGetGrappaSessionId(conn2)
p(f"  grappa={g}")

for i in range(6):
    msg, name = read_msg(conn2, timeout_sec=5)
    if name in ["TIMEOUT", None]:
        p(f"  [{i}] {name or 'NULL'}")
        break
    g = ATH.ATHostConnectionGetGrappaSessionId(conn2)
    p(f"  [{i}] << {name} (grappa={g})")

    if name == "SyncAllowed":
        err = ATH.ATHostConnectionSendHostInfo(conn2, hi)
        p(f"       SendHostInfo: {err}")
        break

ATH.ATHostConnectionInvalidate(conn2)
ATH.ATHostConnectionRelease(conn2)

# ══════════════════════════════════════════════════════════════════════════
# APPROACH 3: Try different flags for CreateWithLibrary
# ══════════════════════════════════════════════════════════════════════════
p("\n\n=== APPROACH 3: Different flags ===")
for flags in [0, 1, 2, 3, 4, 8, 16, 256]:
    conn3 = ATH.ATHostConnectionCreateWithLibrary(cfstr("com.softorino.bigsync"), cfstr(udid), flags)
    if conn3:
        g = ATH.ATHostConnectionGetGrappaSessionId(conn3)
        s = ATH.ATHostConnectionGetCurrentSessionNumber(conn3)
        # Quick read one message
        msg, name = read_msg(conn3, timeout_sec=3)
        p(f"  flags={flags}: conn={hex(conn3)} grappa={g} session={s} first_msg={name}")
        ATH.ATHostConnectionInvalidate(conn3)
        ATH.ATHostConnectionRelease(conn3)
    else:
        p(f"  flags={flags}: NULL")

p("\n[+] Done")
