#!/usr/bin/env python3
"""
ATC sync with DUAL plists in correct locations:
  - Plist A (insert_track): /iTunes_Control/Music/Sync/Sync_XXXX.plist (NO CIG)
  - Plist B (update_db_info): /iTunes_Control/Sync/Media/Sync_XXXX.plist + .cig

Based on go-tunes structure where dataclass-specific plist goes under
/iTunes_Control/{Dataclass}/Sync/ and Media ops go under /iTunes_Control/Sync/Media/.
"""
import asyncio
import ctypes
from ctypes import (c_void_p, c_char_p, c_int, c_uint, c_long,
                    CFUNCTYPE, POINTER, byref, cast)
import signal, sys, os, random, string, plistlib, datetime

def p(msg): print(msg, flush=True)
def timeout_handler(signum, frame): raise TimeoutError()
signal.signal(signal.SIGALRM, timeout_handler)

CF = ctypes.cdll.LoadLibrary('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
MD = ctypes.cdll.LoadLibrary('/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice')
ATH = ctypes.cdll.LoadLibrary('/System/Library/PrivateFrameworks/AirTrafficHost.framework/AirTrafficHost')
CIG = ctypes.cdll.LoadLibrary(os.path.join(os.path.dirname(__file__), 'cig', 'libcig.dylib'))
CIG.cig_calc.restype = c_int
CIG.cig_calc.argtypes = [c_char_p, c_char_p, c_int, c_char_p, POINTER(c_int)]

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
def compute_cig(grappa, plist_data):
    out = ctypes.create_string_buffer(21)
    olen = c_int(21)
    if CIG.cig_calc(grappa, plist_data, len(plist_data), out, byref(olen)) == 1:
        return out.raw[:olen.value]
    return None
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

# ============================================================
# [1] ATC Handshake
# ============================================================
p('\n[1] ATC Handshake...')
conn = ATH.ATHostConnectionCreateWithLibrary(cfstr('com.mediaporter.sync'), cfstr(found[1]), 0)

ATH.ATHostConnectionSendHostInfo(conn, cfdict(
    LibraryID=cfstr('MEDIAPORTER00001'), SyncHostName=cfstr('m3max'),
    SyncedDataclasses=CF.CFArrayCreateMutable(kCFAllocatorDefault, 0, kCFTypeArrayCallBacks),
    Version=cfstr('12.8')))
read_until(conn, 'SyncAllowed')

grappa_cf = CF.CFDataCreate(kCFAllocatorDefault, grappa_bytes, len(grappa_bytes))
hi = cfdict(Grappa=grappa_cf, LibraryID=cfstr('MEDIAPORTER00001'), SyncHostName=cfstr('m3max'),
    SyncedDataclasses=CF.CFArrayCreateMutable(kCFAllocatorDefault, 0, kCFTypeArrayCallBacks), Version=cfstr('12.8'))
dc_arr = CF.CFArrayCreateMutable(kCFAllocatorDefault, 0, kCFTypeArrayCallBacks)
CF.CFArrayAppendValue(dc_arr, cfstr('Media'))
CF.CFArrayAppendValue(dc_arr, cfstr('Keybag'))
ATH.ATHostConnectionSendMessage(conn, ATH.ATCFMessageCreate(0, cfstr('RequestingSync'),
    cfdict(DataclassAnchors=cfdict(Media=cfnum32(0)), Dataclasses=dc_arr, HostInfo=hi)))
msg, _ = read_until(conn, 'ReadyForSync')
if not msg:
    p('FAILED: No ReadyForSync'); sys.exit(1)

device_grappa = extract_device_grappa(msg)
anchor = extract_anchor(msg)
new_anchor = anchor + 1
p(f'  Device Grappa: {len(device_grappa)}B, anchor: {anchor} → {new_anchor}')

# ============================================================
# [2] AFC: Upload file + write DUAL sync plists
# ============================================================
asset_id = random.randint(100000000000000000, 999999999999999999)
slot = f'F{random.randint(0,49):02d}'
fname = ''.join(random.choices(string.ascii_uppercase, k=4)) + '.mp4'
device_path = f'/iTunes_Control/Music/{slot}/{fname}'
p(f'\n[2] AFC: asset_id={asset_id}, path={device_path}')

# Plist A: Dataclass-specific with insert_track (NO CIG)
# Path: /iTunes_Control/Music/Sync/Sync_XXXX.plist
plist_a = plistlib.dumps({
    'revision': new_anchor,
    'timestamp': datetime.datetime.now(datetime.timezone.utc),
    'operations': [
        {'operation': 'update_db_info', 'pid': 0, 'db_info': {
            'audio_language': 0, 'subtitle_language': 0, 'primary_container_pid': 0}},
        {'operation': 'insert_track', 'pid': asset_id, 'item': {
            'title': 'MediaPorter Test', 'sort_name': 'MediaPorter Test',
            'total_time_ms': 125, 'media_kind': 1024,
            'year': 2026, 'genre': 'Home Video',
        }, 'track_info': {
            'location': device_path,
            'file_size': file_size,
        }},
    ]
}, fmt=plistlib.FMT_XML)

# Plist B: Generic Media operations (WITH CIG)
# Path: /iTunes_Control/Sync/Media/Sync_XXXX.plist + .cig
plist_b = plistlib.dumps({
    'revision': new_anchor,
    'timestamp': datetime.datetime.now(datetime.timezone.utc),
    'operations': [
        {'operation': 'update_db_info', 'pid': 0, 'db_info': {
            'audio_language': 0, 'subtitle_language': 0, 'primary_container_pid': 0}},
    ]
}, fmt=plistlib.FMT_XML)

cig_bytes = compute_cig(device_grappa, plist_b)
p(f'  Plist A (insert_track): {len(plist_a)}B')
p(f'  Plist B (db_info+CIG): {len(plist_b)}B, CIG: {len(cig_bytes) if cig_bytes else "FAIL"}B')

async def afc():
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.afc import AfcService
    ld = await create_using_usbmux()
    async with AfcService(ld) as a:
        # Upload video
        try: await a.makedirs(f'/iTunes_Control/Music/{slot}')
        except: pass
        with open(VIDEO, 'rb') as f:
            await a.set_file_contents(device_path, f.read())
        p(f'  Video → {device_path}')

        # Plist A: /iTunes_Control/Music/Sync/
        try: await a.makedirs('/iTunes_Control/Music/Sync')
        except: pass
        pa_path = f'/iTunes_Control/Music/Sync/Sync_{new_anchor:08d}.plist'
        await a.set_file_contents(pa_path, plist_a)
        p(f'  Plist A → {pa_path}')

        # Plist B: /iTunes_Control/Sync/Media/
        try: await a.makedirs('/iTunes_Control/Sync/Media')
        except: pass
        pb_path = f'/iTunes_Control/Sync/Media/Sync_{new_anchor:08d}.plist'
        await a.set_file_contents(pb_path, plist_b)
        if cig_bytes:
            await a.set_file_contents(pb_path + '.cig', cig_bytes)
        p(f'  Plist B + CIG → {pb_path}')

asyncio.run(afc())

# ============================================================
# [3] MetadataSyncFinished
# ============================================================
p(f'\n[3] MetadataSyncFinished (anchor={new_anchor})...')
ATH.ATHostConnectionSendMetadataSyncFinished(conn,
    cfdict(Keybag=cfnum32(1), Media=cfnum32(1)),
    cfdict(Media=cfnum32(new_anchor)))

# ============================================================
# [4] Read responses
# ============================================================
p('\n[4] Reading responses...')
for i in range(15):
    msg, name = read_msg(conn, 10)
    if name in ['TIMEOUT', None]: p(f'  << {name}'); break
    p(f'  << {name}')
    CF.CFShow(msg)
    if name == 'AssetManifest': p('  *** ASSET MANIFEST! ***')
    if name == 'SyncFinished': break

ATH.ATHostConnectionInvalidate(conn)
ATH.ATHostConnectionRelease(conn)
p(f'\nDone — check TV app!')
