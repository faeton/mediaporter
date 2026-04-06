#!/usr/bin/env python3
"""
ATC file transfer via RAW service connection.

Theory: ATHostConnectionSendMessage sends on the COMMAND channel.
FileBegin/FileComplete need to go on the DATA channel — a separate
raw connection to com.apple.atc. The framework manages this internally
but we can do it ourselves.

Wire format: 4-byte LE length + binary plist
"""
import asyncio, ctypes, signal, sys, os, random, string, plistlib, struct
from ctypes import (c_void_p, c_char_p, c_int, c_uint, c_long,
                    c_int64, CFUNCTYPE, POINTER, byref, cast)

def p(msg): print(msg, flush=True)
def timeout_handler(signum, frame): raise TimeoutError()
signal.signal(signal.SIGALRM, timeout_handler)

CF = ctypes.cdll.LoadLibrary('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
MD = ctypes.cdll.LoadLibrary('/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice')
ATH = ctypes.cdll.LoadLibrary('/System/Library/PrivateFrameworks/AirTrafficHost.framework/AirTrafficHost')

kCFAllocatorDefault = c_void_p.in_dll(CF, 'kCFAllocatorDefault')
kCFTypeDictionaryKeyCallBacks = c_void_p.in_dll(CF, 'kCFTypeDictionaryKeyCallBacks')
kCFTypeDictionaryValueCallBacks = c_void_p.in_dll(CF, 'kCFTypeDictionaryValueCallBacks')
kCFTypeArrayCallBacks = c_void_p.in_dll(CF, 'kCFTypeArrayCallBacks')
kCFRunLoopDefaultMode = c_void_p.in_dll(CF, 'kCFRunLoopDefaultMode')

for fn, rt, at in [
    ('CFStringCreateWithCString', c_void_p, [c_void_p, c_char_p, c_uint]),
    ('CFStringGetCString', ctypes.c_bool, [c_void_p, c_char_p, c_int, c_uint]),
    ('CFDictionaryCreateMutable', c_void_p, [c_void_p, c_int, c_void_p, c_void_p]),
    ('CFDictionarySetValue', None, [c_void_p, c_void_p, c_void_p]),
    ('CFDictionaryGetValue', c_void_p, [c_void_p, c_void_p]),
    ('CFArrayCreateMutable', c_void_p, [c_void_p, c_int, c_void_p]),
    ('CFArrayAppendValue', None, [c_void_p, c_void_p]),
    ('CFRunLoopRunInMode', c_int, [c_void_p, ctypes.c_double, ctypes.c_bool]),
    ('CFShow', None, [c_void_p]),
    ('CFNumberCreate', c_void_p, [c_void_p, c_int, c_void_p]),
    ('CFDataCreate', c_void_p, [c_void_p, c_char_p, c_long]),
    ('CFDataGetBytePtr', ctypes.POINTER(ctypes.c_ubyte), [c_void_p]),
    ('CFDataGetLength', c_long, [c_void_p]),
    ('CFGetTypeID', c_long, [c_void_p]),
    ('CFDictionaryGetTypeID', c_long, []),
    ('CFDataGetTypeID', c_long, []),
    ('CFStringGetTypeID', c_long, []),
]:
    getattr(CF, fn).restype = rt
    if at: getattr(CF, fn).argtypes = at

AMDeviceNotificationCallback = CFUNCTYPE(None, c_void_p, c_void_p)
MD.AMDeviceNotificationSubscribe.restype = c_int
MD.AMDeviceNotificationSubscribe.argtypes = [AMDeviceNotificationCallback, c_uint, c_uint, c_void_p, POINTER(c_void_p)]
MD.AMDeviceCopyDeviceIdentifier.restype = c_void_p
MD.AMDeviceCopyDeviceIdentifier.argtypes = [c_void_p]
MD.AMDeviceRetain.restype = c_void_p
MD.AMDeviceRetain.argtypes = [c_void_p]
MD.AMDeviceConnect.restype = c_int
MD.AMDeviceConnect.argtypes = [c_void_p]
MD.AMDeviceStartSession.restype = c_int
MD.AMDeviceStartSession.argtypes = [c_void_p]
MD.AMDeviceSecureStartService.restype = c_int
MD.AMDeviceSecureStartService.argtypes = [c_void_p, c_void_p, c_void_p, POINTER(c_void_p)]

# AMDServiceConnection functions for raw I/O
MD.AMDServiceConnectionSend.restype = c_long
MD.AMDServiceConnectionSend.argtypes = [c_void_p, c_char_p, c_long]
MD.AMDServiceConnectionReceive.restype = c_long
MD.AMDServiceConnectionReceive.argtypes = [c_void_p, c_char_p, c_long]

for fn, rt, at in [
    ('ATHostConnectionCreateWithLibrary', c_void_p, [c_void_p, c_void_p, c_uint]),
    ('ATHostConnectionSendHostInfo', c_void_p, [c_void_p, c_void_p]),
    ('ATHostConnectionReadMessage', c_void_p, [c_void_p]),
    ('ATHostConnectionSendMessage', c_int, [c_void_p, c_void_p]),
    ('ATHostConnectionSendMetadataSyncFinished', c_int, [c_void_p, c_void_p, c_void_p]),
    ('ATHostConnectionInvalidate', c_int, [c_void_p]),
    ('ATHostConnectionRelease', None, [c_void_p]),
    ('ATCFMessageGetName', c_void_p, [c_void_p]),
    ('ATCFMessageGetParam', c_void_p, [c_void_p, c_void_p]),
    ('ATCFMessageCreate', c_void_p, [c_uint, c_void_p, c_void_p]),
]:
    getattr(ATH, fn).restype = rt; getattr(ATH, fn).argtypes = at

def cfstr(s): return CF.CFStringCreateWithCString(kCFAllocatorDefault, s.encode('utf-8'), 0x08000100)
def cfstr_to_str(cf):
    if not cf: return None
    buf = ctypes.create_string_buffer(4096)
    return buf.value.decode('utf-8') if CF.CFStringGetCString(cf, buf, 4096, 0x08000100) else None
def cfnum32(v):
    val = ctypes.c_int32(v); return CF.CFNumberCreate(kCFAllocatorDefault, 3, byref(val))
def cfdict(**kwargs):
    d = CF.CFDictionaryCreateMutable(kCFAllocatorDefault, 0, kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks)
    for k, v in kwargs.items(): CF.CFDictionarySetValue(d, cfstr(k), v)
    return d
def read_msg(conn, to=8):
    signal.alarm(to)
    try:
        msg = ATH.ATHostConnectionReadMessage(conn)
        signal.alarm(0)
        if not msg: return None, None
        return msg, cfstr_to_str(ATH.ATCFMessageGetName(msg))
    except TimeoutError:
        signal.alarm(0)
        return None, 'TIMEOUT'
def read_until(conn, target, max_msgs=10, to=5):
    for _ in range(max_msgs):
        msg, name = read_msg(conn, to)
        if name in ['TIMEOUT', None]: p(f'  << {name}'); return None, name
        p(f'  << {name}')
        if name == target: return msg, name
    return None, 'MAX_MSGS'
def extract_device_grappa(msg):
    di = ATH.ATCFMessageGetParam(msg, cfstr('DeviceInfo'))
    if not di or CF.CFGetTypeID(di) != CF.CFDictionaryGetTypeID(): return None
    g = CF.CFDictionaryGetValue(di, cfstr('Grappa'))
    if not g or CF.CFGetTypeID(g) != CF.CFDataGetTypeID(): return None
    return bytes(CF.CFDataGetBytePtr(g)[:CF.CFDataGetLength(g)])
def extract_anchor(msg):
    anchors = ATH.ATCFMessageGetParam(msg, cfstr('DataclassAnchors'))
    if not anchors: return 0
    val = CF.CFDictionaryGetValue(anchors, cfstr('Media'))
    if not val: return 0
    if CF.CFGetTypeID(val) == CF.CFStringGetTypeID():
        return int(cfstr_to_str(val))
    return 0

# ============================================================
# Raw ATC wire protocol helpers
# ============================================================
def atc_send_raw(svc_conn, msg_dict):
    """Send a plist message on the raw ATC wire: 4-byte LE length + binary plist."""
    plist_data = plistlib.dumps(msg_dict, fmt=plistlib.FMT_BINARY)
    header = struct.pack('<I', len(plist_data))
    total = header + plist_data
    sent = MD.AMDServiceConnectionSend(svc_conn, total, len(total))
    return sent

def atc_recv_raw(svc_conn, timeout_ms=5000):
    """Receive a plist message from raw ATC wire."""
    header = ctypes.create_string_buffer(4)
    n = MD.AMDServiceConnectionReceive(svc_conn, header, 4)
    if n != 4:
        return None
    length = struct.unpack('<I', header.raw)[0]
    if length > 10_000_000:  # sanity check
        return None
    body = ctypes.create_string_buffer(length)
    received = 0
    while received < length:
        n = MD.AMDServiceConnectionReceive(svc_conn, ctypes.cast(ctypes.addressof(body) + received, c_char_p), length - received)
        if n <= 0: break
        received += n
    if received == length:
        return plistlib.loads(body.raw)
    return None

# ============================================================
VIDEO = sys.argv[1] if len(sys.argv) > 1 else 'test_fixtures/output/test_tiny_red.m4v'
file_size = os.path.getsize(VIDEO)

# Find device
found = [None, None]
@AMDeviceNotificationCallback
def cb(info_ptr, _):
    d = cast(info_ptr, POINTER(c_void_p))[0]
    if d and not found[0]:
        MD.AMDeviceRetain(d); found[0] = d
        found[1] = cfstr_to_str(MD.AMDeviceCopyDeviceIdentifier(d))
n = c_void_p()
MD.AMDeviceNotificationSubscribe(cb, 0, 0, None, byref(n))
for _ in range(50):
    CF.CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, False)
    if found[0]: break
if not found[0]: p('No device'); sys.exit(1)
p(f'Device: {found[1][:12]}...')

# ============================================================
# [1] ATC Handshake via ATHostConnection (gets us ReadyForSync)
# ============================================================
p('\n[1] ATC Handshake...')
with open('traces/grappa.bin', 'rb') as f: grappa_bytes = f.read()

conn = ATH.ATHostConnectionCreateWithLibrary(cfstr('com.mediaporter.sync'), cfstr(found[1]), 0)
ATH.ATHostConnectionSendHostInfo(conn, cfdict(
    LibraryID=cfstr('MEDIAPORTER00001'), SyncHostName=cfstr('m3max'),
    SyncedDataclasses=CF.CFArrayCreateMutable(kCFAllocatorDefault, 0, kCFTypeArrayCallBacks),
    Version=cfstr('12.8')))
read_until(conn, 'SyncAllowed')

grappa_cf = CF.CFDataCreate(kCFAllocatorDefault, grappa_bytes, len(grappa_bytes))
hi = cfdict(Grappa=grappa_cf, LibraryID=cfstr('MEDIAPORTER00001'), SyncHostName=cfstr('m3max'),
    SyncedDataclasses=CF.CFArrayCreateMutable(kCFAllocatorDefault, 0, kCFTypeArrayCallBacks), Version=cfstr('12.8'))
dc = CF.CFArrayCreateMutable(kCFAllocatorDefault, 0, kCFTypeArrayCallBacks)
CF.CFArrayAppendValue(dc, cfstr('Media'))
CF.CFArrayAppendValue(dc, cfstr('Keybag'))
ATH.ATHostConnectionSendMessage(conn, ATH.ATCFMessageCreate(0, cfstr('RequestingSync'),
    cfdict(DataclassAnchors=cfdict(Media=cfnum32(0)), Dataclasses=dc, HostInfo=hi)))
msg, _ = read_until(conn, 'ReadyForSync')
if not msg: p('FAILED: No ReadyForSync'); sys.exit(1)

device_grappa = extract_device_grappa(msg)
anchor = extract_anchor(msg)
new_anchor = anchor + 1
p(f'  Device Grappa: {len(device_grappa)}B, anchor: {anchor} → {new_anchor}')

# ============================================================
# [2] Open a SEPARATE raw ATC service connection
# ============================================================
p('\n[2] Opening raw ATC service connection...')
rc = MD.AMDeviceConnect(found[0])
p(f'  AMDeviceConnect: {rc}')
rc = MD.AMDeviceStartSession(found[0])
p(f'  AMDeviceStartSession: {rc}')

atc_svc = c_void_p()
rc = MD.AMDeviceSecureStartService(found[0], cfstr('com.apple.atc'), None, byref(atc_svc))
p(f'  AMDeviceSecureStartService(com.apple.atc): rc={rc}, conn={atc_svc.value}')

if not atc_svc.value:
    p('  FAILED to start ATC service')
    sys.exit(1)

# ============================================================
# [3] Upload file via AFC
# ============================================================
asset_id = random.randint(100000000000000000, 999999999999999999)
slot = f'F{random.randint(0,49):02d}'
fname = ''.join(random.choices(string.ascii_uppercase, k=4)) + '.mp4'
device_path = f'/iTunes_Control/Music/{slot}/{fname}'

p(f'\n[3] AFC upload: {device_path}')
async def afc_upload():
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.afc import AfcService
    ld = await create_using_usbmux()
    async with AfcService(ld) as a:
        try: await a.makedirs(f'/iTunes_Control/Music/{slot}')
        except: pass
        with open(VIDEO, 'rb') as f:
            await a.set_file_contents(device_path, f.read())
        p(f'  Uploaded → {device_path}')
asyncio.run(afc_upload())

# ============================================================
# [4] Send FileBegin on RAW ATC connection
# ============================================================
p(f'\n[4] Sending FileBegin on raw ATC...')
# ATC wire message format: {Command, Id, Params, Session, Type}
file_begin_msg = {
    'Command': 'FileBegin',
    'Params': {
        'AssetID': asset_id,
        'Dataclass': 'Media',
        'FileSize': file_size,
        'TotalSize': file_size,
    },
    'Session': 0,
    'Type': 0,
}
sent = atc_send_raw(atc_svc, file_begin_msg)
p(f'  Sent FileBegin: {sent} bytes')

# ============================================================
# [5] Send file data as FileProgress messages
# ============================================================
p(f'\n[5] Sending file data via FileProgress...')
with open(VIDEO, 'rb') as f:
    video_data = f.read()

CHUNK_SIZE = 262144  # 256KB chunks
offset = 0
chunk_num = 0
while offset < len(video_data):
    chunk = video_data[offset:offset + CHUNK_SIZE]
    progress_msg = {
        'Command': 'FileProgress',
        'Params': {
            'AssetID': asset_id,
            'Dataclass': 'Media',
            'Data': chunk,
        },
        'Session': 0,
        'Type': 0,
    }
    sent = atc_send_raw(atc_svc, progress_msg)
    chunk_num += 1
    offset += len(chunk)
    p(f'  Chunk {chunk_num}: {len(chunk)}B (sent={sent})')

# ============================================================
# [6] Send FileComplete on raw ATC
# ============================================================
p(f'\n[6] Sending FileComplete on raw ATC...')
file_complete_msg = {
    'Command': 'FileComplete',
    'Params': {
        'AssetID': asset_id,
        'Dataclass': 'Media',
        'AssetPath': device_path,
    },
    'Session': 0,
    'Type': 0,
}
sent = atc_send_raw(atc_svc, file_complete_msg)
p(f'  Sent FileComplete: {sent} bytes')

# ============================================================
# [7] MetadataSyncFinished + read responses via ATHostConnection
# ============================================================
p(f'\n[7] MetadataSyncFinished (anchor={new_anchor})...')
ATH.ATHostConnectionSendMetadataSyncFinished(conn,
    cfdict(Keybag=cfnum32(1), Media=cfnum32(1)),
    cfdict(Media=cfnum32(new_anchor)))

p('\n[8] Reading responses...')
for i in range(15):
    msg, name = read_msg(conn, 10)
    if name in ['TIMEOUT', None]: p(f'  << {name}'); break
    p(f'  << {name}')
    CF.CFShow(msg)
    if name == 'AssetManifest': p('  *** ASSET MANIFEST! ***')
    if name == 'SyncFinished': break

# Also try reading from raw ATC connection
p('\n[9] Reading from raw ATC connection...')
for i in range(5):
    resp = atc_recv_raw(atc_svc)
    if resp:
        p(f'  Raw ATC response: {resp}')
    else:
        p(f'  No response from raw ATC')
        break

ATH.ATHostConnectionInvalidate(conn)
ATH.ATHostConnectionRelease(conn)
p(f'\nDone — check TV app for {device_path}')
