#!/usr/bin/env python3
"""
File transfer v2: Use AMDServiceConnectionSend for raw file data.

third-party tool imports both ATHostConnectionSendFileProgress AND AMDServiceConnectionSend.
The plist messages (FileBegin/FileComplete) go via ATHostConnection,
but actual file bytes likely go via raw AMDServiceConnection.

Also: third-party tool's method signature is fileBegin:type:fileSize:totalSize:
suggesting FileBegin takes type (media type), fileSize, totalSize params.
"""
import ctypes
from ctypes import c_void_p, c_char_p, c_int, c_uint, c_int64, POINTER, byref
import signal, sys, os, struct, plistlib, time

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
MD.AMDeviceConnect.restype = c_int; MD.AMDeviceConnect.argtypes = [c_void_p]
MD.AMDeviceValidatePairing.restype = c_int; MD.AMDeviceValidatePairing.argtypes = [c_void_p]
MD.AMDeviceStartSession.restype = c_int; MD.AMDeviceStartSession.argtypes = [c_void_p]
MD.AMDeviceCopyDeviceIdentifier.restype = c_void_p; MD.AMDeviceCopyDeviceIdentifier.argtypes = [c_void_p]
MD.AMDeviceSecureStartService.restype = c_int
MD.AMDeviceSecureStartService.argtypes = [c_void_p, c_void_p, c_void_p, POINTER(c_void_p)]
MD.AMDServiceConnectionGetSocket.restype = c_int
MD.AMDServiceConnectionGetSocket.argtypes = [c_void_p]
MD.AMDServiceConnectionSend.restype = c_int
MD.AMDServiceConnectionSend.argtypes = [c_void_p, c_void_p, c_uint]
MD.AMDServiceConnectionReceive.restype = c_int
MD.AMDServiceConnectionReceive.argtypes = [c_void_p, c_void_p, c_uint]
MD.AMDServiceConnectionGetSecureIOContext.restype = c_void_p
MD.AMDServiceConnectionGetSecureIOContext.argtypes = [c_void_p]

ATH.ATHostConnectionCreateWithLibrary.restype = c_void_p
ATH.ATHostConnectionCreateWithLibrary.argtypes = [c_void_p, c_void_p, c_uint]
ATH.ATHostConnectionGetCurrentSessionNumber.restype = c_uint
ATH.ATHostConnectionGetCurrentSessionNumber.argtypes = [c_void_p]
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

def send_raw(conn, session, command, params):
    msg = ATH.ATCFMessageCreate(session, cfstr(command), params)
    if not msg: return -1
    return ATH.ATHostConnectionSendMessage(conn, msg)

def encode_plist(msg):
    data = plistlib.dumps(msg, fmt=plistlib.FMT_BINARY)
    return struct.pack("<I", len(data)) + data

def recv_exact(svc, n, timeout=10):
    buf = ctypes.create_string_buffer(n)
    total = 0
    signal.alarm(timeout)
    try:
        while total < n:
            r = MD.AMDServiceConnectionReceive(svc, ctypes.addressof(buf) + total, n - total)
            if r <= 0: break
            total += r
        signal.alarm(0)
        return buf.raw[:total] if total > 0 else None
    except TimeoutError:
        signal.alarm(0)
        return None

def recv_plist(svc, timeout=10):
    h = recv_exact(svc, 4, timeout)
    if not h: return None
    length = struct.unpack("<I", h)[0]
    data = recv_exact(svc, length, timeout)
    if not data: return None
    return plistlib.loads(data)

def send_plist(svc, msg):
    data = encode_plist(msg)
    buf = ctypes.create_string_buffer(data)
    return MD.AMDServiceConnectionSend(svc, buf, len(data))

def send_raw_bytes(svc, data):
    """Send raw bytes via AMDServiceConnectionSend."""
    buf = ctypes.create_string_buffer(data)
    return MD.AMDServiceConnectionSend(svc, buf, len(data))


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

with open(test_file, 'rb') as f:
    file_data = f.read()

device_list = MD.AMDCreateDeviceList()
device = CF.CFArrayGetValueAtIndex(device_list, 0)
udid = cfstr_to_str(MD.AMDeviceCopyDeviceIdentifier(device))
p(f"[+] Device: {udid}")

MD.AMDeviceConnect(device)
MD.AMDeviceValidatePairing(device)
MD.AMDeviceStartSession(device)

# ══════════════════════════════════════════════════════════════════════════
# APPROACH A: Use raw ATC service + plist protocol for EVERYTHING
# (FileBegin as plist, file data as raw bytes on same socket, FileComplete as plist)
# ══════════════════════════════════════════════════════════════════════════
p("\n=== APPROACH A: Raw ATC socket with plist + raw bytes ===")

svc = c_void_p()
err = MD.AMDeviceSecureStartService(device, cfstr("com.apple.atc"), None, byref(svc))
p(f"  ATC service: err={err}")

# Read Capabilities
caps = recv_plist(svc)
p(f"  << {caps.get('Command')}")

# Send Capabilities response
send_plist(svc, {
    'Command': 'Capabilities',
    'Params': {
        'GrappaSupportInfo': {'version': 1, 'deviceType': 1, 'protocolVersion': 1},
        'HostVersion': '12.13.2.3',
    },
    'Type': 1, 'Session': 0, 'Id': 1,
})
p("  >> Capabilities")

# Read InstalledAssets, AssetMetrics, SyncAllowed
session = 0
for i in range(5):
    msg = recv_plist(svc, timeout=5)
    if not msg: break
    cmd = msg.get('Command', '?')
    session = msg.get('Session', session)
    p(f"  << {cmd} (session={session})")
    if cmd == 'SyncAllowed':
        break

# Send HostInfo
send_plist(svc, {
    'Command': 'HostInfo',
    'Params': {
        'HostName': 'third-party sync tool', 'HostID': 'com.softorino.bigsync',
        'Version': '12.13.2.3', 'LibraryPersistentID': '7F4D6E2B1A3C5D8E',
    },
    'Type': 0, 'Session': session, 'Id': 2,
})
p("  >> HostInfo")

# Send FileBegin — tell device we're about to send a file
remote_path = f"iTunes_Control/Music/F00/{file_name}"
send_plist(svc, {
    'Command': 'FileBegin',
    'Params': {
        'Path': remote_path,
        'FileSize': file_size,
        'TotalSize': file_size,
        'TransferType': 0,
    },
    'Type': 0, 'Session': session, 'Id': 3,
})
p(f"  >> FileBegin ({file_name}, {file_size} bytes)")

# Check for response
msg = recv_plist(svc, timeout=3)
if msg:
    cmd = msg.get('Command', '?')
    p(f"  << {cmd}")
    if cmd == 'SyncFailed':
        ec = msg.get('Params', {}).get('ErrorCode')
        rv = msg.get('Params', {}).get('RequiredVersion')
        p(f"     ErrorCode={ec}, RequiredVersion={rv}")
else:
    p("  No response to FileBegin — sending file data...")

    # Send raw file data directly on the socket
    chunk_size = 65536
    offset = 0
    chunks = 0
    while offset < len(file_data):
        chunk = file_data[offset:offset+chunk_size]
        sent = send_raw_bytes(svc, chunk)
        if sent <= 0:
            p(f"  Send failed at offset {offset}: {sent}")
            break
        offset += sent if sent > 0 else len(chunk)
        chunks += 1
        if chunks <= 3 or chunks % 10 == 0:
            p(f"  Sent chunk {chunks}: {offset}/{file_size} bytes")

    p(f"  File data sent: {offset}/{file_size} bytes in {chunks} chunks")

    # Send FileComplete
    send_plist(svc, {
        'Command': 'FileComplete',
        'Params': {
            'Path': remote_path,
            'FileSize': file_size,
        },
        'Type': 0, 'Session': session, 'Id': 4,
    })
    p("  >> FileComplete")

    # Send AssetCompleted
    send_plist(svc, {
        'Command': 'AssetCompleted',
        'Params': {
            'Path': remote_path,
            'DataClass': 'com.apple.Movies',
            'AssetIdentifier': file_name,
        },
        'Type': 0, 'Session': session, 'Id': 5,
    })
    p("  >> AssetCompleted")

    # Send FinishedSyncingMetadata
    send_plist(svc, {
        'Command': 'FinishedSyncingMetadata',
        'Params': {
            'SyncTypes': {'com.apple.Movies': True},
            'Anchors': {},
        },
        'Type': 0, 'Session': session, 'Id': 6,
    })
    p("  >> FinishedSyncingMetadata")

    # Read responses
    p("\n  Reading responses:")
    for i in range(5):
        msg = recv_plist(svc, timeout=5)
        if not msg:
            p(f"  [{i}] No response")
            break
        cmd = msg.get('Command', '?')
        p(f"  [{i}] << {cmd}")
        params = msg.get('Params', {})
        if 'ErrorCode' in params:
            p(f"       ErrorCode: {params['ErrorCode']}")
        if cmd in ['SyncFinished', 'SyncFailed']:
            break

p("\n[+] Done — check TV app on iPad!")
