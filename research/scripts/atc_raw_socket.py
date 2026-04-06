#!/usr/bin/env python3
"""
PoC: Use AMDeviceSecureStartService to get a raw ATC socket,
then manually speak the ATC protocol. Compare with pymobiledevice3 path.

Also: Read the Capabilities message to see what the device wants for Grappa.
"""
import ctypes
from ctypes import c_void_p, c_char_p, c_int, c_uint, POINTER, byref
import struct
import plistlib
import socket
import signal
import sys
import os

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
MD.AMDServiceConnectionGetSocket.restype = c_int
MD.AMDServiceConnectionGetSocket.argtypes = [c_void_p]

# For SSL context — important for secure services
MD.AMDServiceConnectionGetSecureIOContext.restype = c_void_p
MD.AMDServiceConnectionGetSecureIOContext.argtypes = [c_void_p]

# Send/receive through the service connection (handles SSL)
MD.AMDServiceConnectionSend.restype = c_int
MD.AMDServiceConnectionSend.argtypes = [c_void_p, c_void_p, c_uint]
MD.AMDServiceConnectionReceive.restype = c_int
MD.AMDServiceConnectionReceive.argtypes = [c_void_p, c_void_p, c_uint]

def encode_msg(msg):
    data = plistlib.dumps(msg, fmt=plistlib.FMT_BINARY)
    return struct.pack("<I", len(data)) + data

def recv_exact(svc_conn, n, timeout=10):
    """Receive exactly n bytes via AMDServiceConnectionReceive."""
    buf = ctypes.create_string_buffer(n)
    total = 0
    signal.alarm(timeout)
    try:
        while total < n:
            received = MD.AMDServiceConnectionReceive(svc_conn, ctypes.addressof(buf) + total, n - total)
            if received <= 0:
                signal.alarm(0)
                return None
            total += received
        signal.alarm(0)
        return buf.raw[:total]
    except TimeoutError:
        signal.alarm(0)
        return None

def recv_msg(svc_conn, timeout=10):
    """Receive a plist message from ATC service."""
    header = recv_exact(svc_conn, 4, timeout)
    if not header:
        return None
    length = struct.unpack("<I", header)[0]
    data = recv_exact(svc_conn, length, timeout)
    if not data:
        return None
    return plistlib.loads(data)

def send_msg(svc_conn, msg):
    """Send a plist message to ATC service."""
    data = encode_msg(msg)
    buf = ctypes.create_string_buffer(data)
    sent = MD.AMDServiceConnectionSend(svc_conn, buf, len(data))
    return sent


# ── Device setup ──────────────────────────────────────────────────────────
p("[+] Loading...")
device_list = MD.AMDCreateDeviceList()
count = CF.CFArrayGetCount(device_list)
if count == 0:
    p("[-] No device"); sys.exit(1)

device = CF.CFArrayGetValueAtIndex(device_list, 0)
udid = cfstr_to_str(MD.AMDeviceCopyDeviceIdentifier(device))
p(f"[+] Device: {udid}")

MD.AMDeviceConnect(device)
MD.AMDeviceValidatePairing(device)
MD.AMDeviceStartSession(device)
name = cfstr_to_str(MD.AMDeviceCopyValue(device, None, cfstr("DeviceName")))
p(f"[+] {name}")

# ── Start ATC service ────────────────────────────────────────────────────
p("\n=== Starting com.apple.atc via AMDeviceSecureStartService ===")
svc_conn = c_void_p()
err = MD.AMDeviceSecureStartService(device, cfstr("com.apple.atc"), None, byref(svc_conn))
p(f"  err={err}, conn={hex(svc_conn.value) if svc_conn.value else 'NULL'}")

ssl_ctx = MD.AMDServiceConnectionGetSecureIOContext(svc_conn)
p(f"  SSL context: {hex(ssl_ctx) if ssl_ctx else 'NULL (no SSL)'}")

sock_fd = MD.AMDServiceConnectionGetSocket(svc_conn)
p(f"  Socket FD: {sock_fd}")

if not svc_conn.value:
    p("[-] Failed to start service")
    sys.exit(1)

# ── Read Capabilities from device ─────────────────────────────────────────
p("\n=== Reading device Capabilities ===")
msg = recv_msg(svc_conn, timeout=10)
if msg:
    p(f"  Command: {msg.get('Command')}")
    params = msg.get('Params', {})
    for k, v in params.items():
        if isinstance(v, bytes) and len(v) > 50:
            p(f"  Params.{k}: <{len(v)} bytes>")
        else:
            p(f"  Params.{k}: {v}")
else:
    p("  No Capabilities message received")
    sys.exit(1)

# ── Send our Capabilities response ────────────────────────────────────────
p("\n=== Sending Capabilities response ===")
grappa_info = msg.get('Params', {}).get('GrappaSupportInfo', {})
p(f"  Device GrappaSupportInfo: {grappa_info}")

# Mirror the device's Grappa support
our_caps = {
    'Command': 'Capabilities',
    'Params': {
        'GrappaSupportInfo': {
            'version': grappa_info.get('version', 1),
            'deviceType': 1,  # 1 = host
            'protocolVersion': grappa_info.get('protocolVersion', 1),
        },
        'HostVersion': '12.13.2.3',
    },
    'Type': 1,  # response
    'Session': 0,
    'Id': 1,
}
sent = send_msg(svc_conn, our_caps)
p(f"  Sent: {sent} bytes")

# ── Send HostInfo ─────────────────────────────────────────────────────────
p("\n=== Sending HostInfo ===")
host_info_msg = {
    'Command': 'HostInfo',
    'Params': {
        'HostName': 'mediaporter',
        'HostID': 'com.apple.iTunes',
        'Version': '12.13.2.3',
        'LibraryPersistentID': '0000000000000001',
    },
    'Type': 0,
    'Session': 0,
    'Id': 2,
}
sent = send_msg(svc_conn, host_info_msg)
p(f"  Sent: {sent} bytes")

# ── Read more messages ────────────────────────────────────────────────────
p("\n=== Reading messages ===")
for i in range(10):
    msg = recv_msg(svc_conn, timeout=5)
    if not msg:
        p(f"  [{i}] No more messages")
        break
    cmd = msg.get('Command', '?')
    p(f"  [{i}] << {cmd}")

    params = msg.get('Params', {})
    for k, v in params.items():
        if isinstance(v, bytes) and len(v) > 100:
            p(f"       {k}: <{len(v)} bytes>")
        elif isinstance(v, dict) and len(str(v)) > 200:
            p(f"       {k}: <dict with {len(v)} keys>")
        else:
            p(f"       {k}: {v}")

    if cmd == 'SyncAllowed':
        p("  Got SyncAllowed! Sending RequestingSync...")
        req_sync = {
            'Command': 'RequestingSync',
            'Params': {
                'DataClasses': ['com.apple.media'],
            },
            'Type': 0,
            'Session': msg.get('Session', 0),
            'Id': 3,
        }
        sent = send_msg(svc_conn, req_sync)
        p(f"  Sent RequestingSync: {sent} bytes")

    if cmd == 'SyncFailed':
        ec = params.get('ErrorCode')
        reason = params.get('Reason')
        reqver = params.get('RequiredVersion')
        p(f"  *** SyncFailed: ErrorCode={ec}, Reason={reason}, RequiredVersion={reqver}")
        break

# ── Also test ATC2 ────────────────────────────────────────────────────────
p("\n=== Starting com.apple.atc2 via AMDeviceSecureStartService ===")
svc_conn2 = c_void_p()
err2 = MD.AMDeviceSecureStartService(device, cfstr("com.apple.atc2"), None, byref(svc_conn2))
p(f"  err={err2}, conn={hex(svc_conn2.value) if svc_conn2.value else 'NULL'}")

if svc_conn2.value:
    ssl2 = MD.AMDServiceConnectionGetSecureIOContext(svc_conn2)
    p(f"  SSL context: {hex(ssl2) if ssl2 else 'NULL'}")

    msg2 = recv_msg(svc_conn2, timeout=5)
    if msg2:
        p(f"  ATC2 first message: {msg2.get('Command', '?')}")
        params2 = msg2.get('Params', {})
        for k, v in params2.items():
            if isinstance(v, bytes) and len(v) > 100:
                p(f"       {k}: <{len(v)} bytes>")
            else:
                p(f"       {k}: {v}")
    else:
        p("  No message from ATC2")

p("\n[+] Done")
