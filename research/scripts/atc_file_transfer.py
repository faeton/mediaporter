#!/usr/bin/env python3
"""
ATC file transfer via raw ATCFMessages — no sync plists.

Approach: After ATC handshake, upload file via AFC then send
FileBegin/FileComplete messages to register it in device DB.
This is what third-party tool and Finder do (they never write sync plists).
"""
import asyncio
import ctypes
from ctypes import (c_void_p, c_char_p, c_int, c_uint, c_long,
                    c_int64, CFUNCTYPE, POINTER, byref, cast)
import signal, sys, os, random, string

def p(msg): print(msg, flush=True)
def timeout_handler(signum, frame): raise TimeoutError()
signal.signal(signal.SIGALRM, timeout_handler)

# Frameworks
CF = ctypes.cdll.LoadLibrary('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
MD = ctypes.cdll.LoadLibrary('/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice')
ATH = ctypes.cdll.LoadLibrary('/System/Library/PrivateFrameworks/AirTrafficHost.framework/AirTrafficHost')

# CF helpers
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
    val = ctypes.c_int32(v)
    return CF.CFNumberCreate(kCFAllocatorDefault, 3, byref(val))
def cfnum64(v):
    val = ctypes.c_int64(v)
    return CF.CFNumberCreate(kCFAllocatorDefault, 4, byref(val))
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
def read_all(conn, max_msgs=10, to=5):
    """Read all available messages, print and return them."""
    msgs = []
    for _ in range(max_msgs):
        msg, name = read_msg(conn, to)
        if name in ['TIMEOUT', None]:
            p(f'  << {name}')
            break
        p(f'  << {name}')
        CF.CFShow(msg)
        msgs.append((msg, name))
        if name == 'SyncFinished':
            break
    return msgs
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
def send_atc(conn, command, params):
    """Send a raw ATCFMessage."""
    msg = ATH.ATCFMessageCreate(0, cfstr(command), params)
    if not msg:
        p(f'  !! ATCFMessageCreate({command}) returned NULL')
        return -1
    rc = ATH.ATHostConnectionSendMessage(conn, msg)
    p(f'  >> {command} → rc={rc}')
    return rc

# ============================================================
VIDEO = sys.argv[1] if len(sys.argv) > 1 else 'test_fixtures/output/test_tiny_red.m4v'
GRAPPA = sys.argv[2] if len(sys.argv) > 2 else 'traces/grappa.bin'
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

with open(GRAPPA, 'rb') as f: grappa_bytes = f.read()
p(f'Device: {found[1][:12]}..., file: {VIDEO} ({file_size}B)')

# Generate file placement
asset_id = random.randint(100000000000000000, 999999999999999999)
slot = f'F{random.randint(0,49):02d}'
fname = ''.join(random.choices(string.ascii_uppercase, k=4)) + '.mp4'
device_path = f'/iTunes_Control/Music/{slot}/{fname}'
p(f'AssetID: {asset_id}, path: {device_path}')

# ============================================================
# [1] Upload file via AFC first
# ============================================================
p('\n[1] AFC: Uploading file...')
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
# [2] ATC Handshake: HostInfo → SyncAllowed → RequestingSync → ReadyForSync
# ============================================================
p('\n[2] ATC Handshake...')
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
send_atc(conn, 'RequestingSync',
    cfdict(DataclassAnchors=cfdict(Media=cfnum32(0)), Dataclasses=dc, HostInfo=hi))
msg, _ = read_until(conn, 'ReadyForSync')
if not msg:
    p('FAILED: No ReadyForSync'); sys.exit(1)

device_grappa = extract_device_grappa(msg)
anchor = extract_anchor(msg)
new_anchor = anchor + 1
p(f'  Device Grappa: {len(device_grappa)}B, anchor: {anchor} → {new_anchor}')

# ============================================================
# [3] Send FileBegin (raw ATCFMessage — matching third-party tool's trace)
# ============================================================
# From third-party tool trace:
#   ATCFMessageCreate("FileBegin", {
#     AssetID = 349645419467270165,
#     Dataclass = "Media",
#     FileSize = 2473890,
#     TotalSize = 2473890
#   })
p('\n[3] Sending FileBegin...')
send_atc(conn, 'FileBegin', cfdict(
    AssetID=cfnum64(asset_id),
    Dataclass=cfstr('Media'),
    FileSize=cfnum64(file_size),
    TotalSize=cfnum64(file_size),
))

# ============================================================
# [4] Send FileProgress (report completion — file already on device via AFC)
# ============================================================
p('\n[4] Sending FileProgress...')
# FileProgress likely reports transfer progress. Since file is already
# uploaded via AFC, report 100% in one message.
send_atc(conn, 'FileProgress', cfdict(
    AssetID=cfnum64(asset_id),
    Dataclass=cfstr('Media'),
    Progress=cfnum32(file_size),  # bytes transferred
))

# ============================================================
# [5] Send FileComplete / AssetCompleted
# ============================================================
# From third-party tool trace:
#   ATCFMessageCreate("FileComplete", {
#     AssetID, Dataclass = "Media",
#     AssetPath = "/iTunes_Control/Music/F02/ANNH.mp4"
#   })
p('\n[5] Sending FileComplete...')
send_atc(conn, 'FileComplete', cfdict(
    AssetID=cfnum64(asset_id),
    Dataclass=cfstr('Media'),
    AssetPath=cfstr(device_path),
))

# ============================================================
# [6] MetadataSyncFinished
# ============================================================
p(f'\n[6] MetadataSyncFinished (anchor={new_anchor})...')
ATH.ATHostConnectionSendMetadataSyncFinished(conn,
    cfdict(Keybag=cfnum32(1), Media=cfnum32(1)),
    cfdict(Media=cfnum32(new_anchor)))

# ============================================================
# [7] Read all responses
# ============================================================
p('\n[7] Reading responses...')
msgs = read_all(conn, max_msgs=15, to=8)

for msg, name in msgs:
    if name == 'AssetManifest':
        p('  *** GOT ASSET MANIFEST! ***')

# ============================================================
# Cleanup
# ============================================================
ATH.ATHostConnectionInvalidate(conn)
ATH.ATHostConnectionRelease(conn)
p(f'\nDone — check TV app for {device_path}')
