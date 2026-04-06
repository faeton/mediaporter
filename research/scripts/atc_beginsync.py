#!/usr/bin/env python3
"""
PoC: Full ATC conversation with proper message sequencing.
Focus on getting past ErrorCode 12 by matching Finder's exact flow.

Key insight: The device auto-sends Capabilities → InstalledAssets → AssetMetrics → SyncAllowed.
We need to respond to each correctly, then send BeginSync (not RequestingSync which re-triggers SyncAllowed).
"""
import ctypes
from ctypes import c_void_p, c_char_p, c_int, c_uint, POINTER, byref
import struct, plistlib, signal, sys, json

def p(msg):
    print(msg, flush=True)

def timeout_handler(signum, frame):
    raise TimeoutError()
signal.signal(signal.SIGALRM, timeout_handler)

CF = ctypes.cdll.LoadLibrary('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
MD = ctypes.cdll.LoadLibrary('/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice')

kCFAllocatorDefault = c_void_p.in_dll(CF, 'kCFAllocatorDefault')
CF.CFStringCreateWithCString.restype = c_void_p
CF.CFStringCreateWithCString.argtypes = [c_void_p, c_char_p, c_uint]
CF.CFStringGetCString.restype = ctypes.c_bool
CF.CFStringGetCString.argtypes = [c_void_p, c_char_p, c_int, c_uint]
CF.CFArrayGetCount.restype = c_int
CF.CFArrayGetCount.argtypes = [c_void_p]
CF.CFArrayGetValueAtIndex.restype = c_void_p
CF.CFArrayGetValueAtIndex.argtypes = [c_void_p, c_int]

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
MD.AMDeviceSecureStartService.restype = c_int
MD.AMDeviceSecureStartService.argtypes = [c_void_p, c_void_p, c_void_p, POINTER(c_void_p)]
MD.AMDServiceConnectionGetSocket.restype = c_int
MD.AMDServiceConnectionGetSocket.argtypes = [c_void_p]
MD.AMDServiceConnectionSend.restype = c_int
MD.AMDServiceConnectionSend.argtypes = [c_void_p, c_void_p, c_uint]
MD.AMDServiceConnectionReceive.restype = c_int
MD.AMDServiceConnectionReceive.argtypes = [c_void_p, c_void_p, c_uint]

msg_id_counter = 0

def encode_msg(msg):
    data = plistlib.dumps(msg, fmt=plistlib.FMT_BINARY)
    return struct.pack("<I", len(data)) + data

def recv_exact(svc, n, timeout=10):
    buf = ctypes.create_string_buffer(n)
    total = 0
    signal.alarm(timeout)
    try:
        while total < n:
            r = MD.AMDServiceConnectionReceive(svc, ctypes.addressof(buf) + total, n - total)
            if r <= 0:
                signal.alarm(0)
                return None
            total += r
        signal.alarm(0)
        return buf.raw[:total]
    except TimeoutError:
        signal.alarm(0)
        return None

def recv_msg(svc, timeout=10):
    h = recv_exact(svc, 4, timeout)
    if not h: return None
    length = struct.unpack("<I", h)[0]
    data = recv_exact(svc, length, timeout)
    if not data: return None
    return plistlib.loads(data)

def send_msg(svc, msg):
    global msg_id_counter
    msg_id_counter += 1
    msg['Id'] = msg_id_counter
    data = encode_msg(msg)
    buf = ctypes.create_string_buffer(data)
    return MD.AMDServiceConnectionSend(svc, buf, len(data))

def pp_msg(direction, msg):
    """Pretty print a message."""
    cmd = msg.get('Command', '?')
    session = msg.get('Session', '?')
    type_ = msg.get('Type', '?')
    id_ = msg.get('Id', '?')
    p(f"  {direction} {cmd} (session={session}, type={type_}, id={id_})")
    params = msg.get('Params', {})
    for k, v in sorted(params.items()):
        if isinstance(v, bytes):
            p(f"     {k}: <{len(v)} bytes> {v[:32].hex()}...")
        elif isinstance(v, dict) and len(str(v)) > 150:
            p(f"     {k}: <dict {len(v)} keys>")
        else:
            p(f"     {k}: {v}")


# ── Device ────────────────────────────────────────────────────────────────
device_list = MD.AMDCreateDeviceList()
if CF.CFArrayGetCount(device_list) == 0:
    p("No device"); sys.exit(1)
device = CF.CFArrayGetValueAtIndex(device_list, 0)
udid = cfstr_to_str(MD.AMDeviceCopyDeviceIdentifier(device))
MD.AMDeviceConnect(device)
MD.AMDeviceValidatePairing(device)
MD.AMDeviceStartSession(device)
name = cfstr_to_str(MD.AMDeviceCopyValue(device, None, cfstr("DeviceName")))
p(f"[+] {name} ({udid})")

# ── Start ATC ─────────────────────────────────────────────────────────────
svc = c_void_p()
err = MD.AMDeviceSecureStartService(device, cfstr("com.apple.atc"), None, byref(svc))
p(f"[+] ATC service: err={err}")

# ── Message 1: Device sends Capabilities ──────────────────────────────────
p("\n=== Phase 1: Capabilities exchange ===")
caps = recv_msg(svc)
pp_msg("<<", caps)

# Respond with our Capabilities (match what Finder sends)
our_caps = {
    'Command': 'Capabilities',
    'Params': {
        'GrappaSupportInfo': {
            'version': 1,
            'deviceType': 1,  # host
            'protocolVersion': 1,
        },
        'HostVersion': '12.13.2.3',
        # Additional fields Finder might send:
        'SupportedFeatures': {
            'supportsFileTransfer': True,
            'supportsMediaSync': True,
        },
    },
    'Type': 1,  # response
    'Session': 0,
}
send_msg(svc, our_caps)
p("  >> Capabilities (response)")

# ── Phase 2: Read InstalledAssets + AssetMetrics + SyncAllowed ────────────
p("\n=== Phase 2: Device status messages ===")
device_session = 0
for i in range(5):
    msg = recv_msg(svc, timeout=5)
    if not msg:
        p(f"  [{i}] No more messages")
        break
    cmd = msg.get('Command', '?')
    device_session = msg.get('Session', device_session)
    pp_msg("<<", msg)

    if cmd == 'SyncAllowed':
        p("\n  *** SyncAllowed received!")
        break

# ── Phase 3: Send HostInfo ────────────────────────────────────────────────
p(f"\n=== Phase 3: HostInfo (session={device_session}) ===")
host_info = {
    'Command': 'HostInfo',
    'Params': {
        'HostName': 'mediaporter',
        'HostID': '0A1B2C3D-4E5F-6789-ABCD-EF0123456789',
        'Version': '12.13.2.3',
        'LibraryPersistentID': '7F4D6E2B1A3C5D8E',
    },
    'Type': 0,
    'Session': device_session,
}
send_msg(svc, host_info)
p("  >> HostInfo")

# ── Phase 4: Send RequestingSync ──────────────────────────────────────────
p(f"\n=== Phase 4: RequestingSync ===")
req_sync = {
    'Command': 'RequestingSync',
    'Params': {
        'DataClasses': ['com.apple.media'],
        'SyncTypes': {
            'Movie': True,
            'HomeVideo': True,
        },
    },
    'Type': 0,
    'Session': device_session,
}
send_msg(svc, req_sync)
p("  >> RequestingSync")

# Read response
msg = recv_msg(svc, timeout=5)
if msg:
    pp_msg("<<", msg)
    if msg.get('Command') == 'SyncAllowed':
        p("  Got SyncAllowed again!")

# ── Phase 5: Send BeginSync ──────────────────────────────────────────────
p(f"\n=== Phase 5: BeginSync ===")
begin_sync = {
    'Command': 'BeginSync',
    'Params': {
        'SyncTypes': {
            'com.apple.Movies': True,
        },
        'Anchors': {},
    },
    'Type': 0,
    'Session': device_session,
}
send_msg(svc, begin_sync)
p("  >> BeginSync")

# Read response
for i in range(5):
    msg = recv_msg(svc, timeout=5)
    if not msg:
        p(f"  [{i}] No response")
        break
    pp_msg("<<", msg)
    cmd = msg.get('Command', '?')
    if cmd == 'SyncFailed':
        p("  *** SyncFailed!")
        break
    if cmd == 'ReadyForSync':
        p("  *** ReadyForSync! Grappa accepted!")
        break
    if cmd == 'SyncFinished':
        break

# ── Phase 6: Also try different version strings ──────────────────────────
p("\n=== Phase 6: Try with exact RequiredVersion ===")

# Reconnect
svc2 = c_void_p()
MD.AMDeviceSecureStartService(device, cfstr("com.apple.atc"), None, byref(svc2))

# Read Capabilities
caps2 = recv_msg(svc2)
p(f"  << {caps2.get('Command')}")

# Send Capabilities with version matching RequiredVersion exactly
our_caps2 = {
    'Command': 'Capabilities',
    'Params': {
        'GrappaSupportInfo': {
            'version': 1,
            'deviceType': 1,
            'protocolVersion': 1,
        },
        'HostVersion': '10.5.0.115',  # exact version device requires
    },
    'Type': 1,
    'Session': 0,
}
send_msg(svc2, our_caps2)
p("  >> Capabilities (version=10.5.0.115)")

# Read all
for i in range(5):
    msg = recv_msg(svc2, timeout=5)
    if not msg:
        p(f"  [{i}] No more")
        break
    pp_msg("<<", msg)
    if msg.get('Command') == 'SyncAllowed':
        # Send HostInfo with version
        hi = {
            'Command': 'HostInfo',
            'Params': {
                'HostName': 'mediaporter',
                'HostID': '0A1B2C3D-4E5F-6789-ABCD-EF0123456789',
                'Version': '10.5.0.115',
                'LibraryPersistentID': '7F4D6E2B1A3C5D8E',
            },
            'Type': 0,
            'Session': msg.get('Session', 0),
        }
        send_msg(svc2, hi)
        p("  >> HostInfo (10.5.0.115)")

        # Send RequestingSync
        rs = {
            'Command': 'RequestingSync',
            'Params': {'DataClasses': ['com.apple.media']},
            'Type': 0,
            'Session': msg.get('Session', 0),
        }
        send_msg(svc2, rs)
        p("  >> RequestingSync")

        # Read
        for j in range(3):
            r = recv_msg(svc2, timeout=5)
            if not r: break
            pp_msg("<<", r)
            if r.get('Command') in ['SyncAllowed', 'SyncFailed', 'ReadyForSync']:
                if r.get('Command') == 'SyncAllowed':
                    # Now send BeginSync
                    bs = {
                        'Command': 'BeginSync',
                        'Params': {
                            'SyncTypes': {'com.apple.Movies': True},
                            'Anchors': {},
                        },
                        'Type': 0,
                        'Session': r.get('Session', 0),
                    }
                    send_msg(svc2, bs)
                    p("  >> BeginSync")
                    for k in range(3):
                        rr = recv_msg(svc2, timeout=5)
                        if not rr: break
                        pp_msg("<<", rr)
                        if rr.get('Command') in ['SyncFailed', 'ReadyForSync']:
                            break
                break
        break

p("\n[+] Done")
