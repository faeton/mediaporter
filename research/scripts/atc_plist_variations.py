#!/usr/bin/env python3
"""
Try multiple insert_track plist variations to find what works.
Each variation gets a unique trial name for identification.
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
GRAPPA_PATH = sys.argv[2] if len(sys.argv) > 2 else 'traces/grappa.bin'
VARIATION = int(sys.argv[3]) if len(sys.argv) > 3 else 1
file_size = os.path.getsize(VIDEO)

def make_plist_variation(var, anchor, asset_id, device_path, fname, slot, file_size):
    """Generate different insert_track plist variations."""
    base_loc = f'iTunes_Control/Music/{slot}'
    now = datetime.datetime.now(datetime.timezone.utc)

    if var == 1:
        # Variation 1: go-tunes style — location is full path, binary plist
        desc = "go-tunes style: full path location, binary plist"
        ops = [
            {'operation': 'insert_track', 'pid': asset_id, 'item': {
                'title': f'TinyTestV1', 'sort_name': f'tinytestv1',
                'total_time_ms': 125, 'media_kind': 2},  # 2 = music in go-tunes
            'track_info': {'location': device_path, 'file_size': file_size}},
        ]
        return desc, plistlib.dumps({'revision': anchor, 'timestamp': now,
            'operations': ops}, fmt=plistlib.FMT_BINARY)

    elif var == 2:
        # Variation 2: Minimal — just insert_track, no update_db_info, XML
        desc = "Minimal: insert_track only, no update_db_info"
        ops = [
            {'operation': 'insert_track', 'pid': asset_id, 'item': {
                'title': f'TinyTestV2', 'sort_name': f'tinytestv2',
                'total_time_ms': 125, 'media_kind': 1024,
            }, 'track_info': {
                'location': fname, 'base_location': base_loc,
                'file_size': file_size,
            }},
        ]
        return desc, plistlib.dumps({'revision': anchor, 'timestamp': now,
            'operations': ops}, fmt=plistlib.FMT_XML)

    elif var == 3:
        # Variation 3: go-tunes EXACT ringtone format adapted for video
        desc = "go-tunes exact: media_kind=32 (ringtone) to test if format works at all"
        ops = [
            {'operation': 'update_db_info', 'pid': 0, 'db_info': {
                'audio_language': 0, 'subtitle_language': 0, 'primary_container_pid': 0}},
            {'operation': 'insert_track', 'pid': asset_id, 'item': {
                'title': f'TinyTestV3', 'sort_name': f'tinytestv3',
                'total_time_ms': 125, 'media_kind': 32,  # 32 = ringtone
            }, 'track_info': {'location': device_path, 'file_size': file_size}},
        ]
        return desc, plistlib.dumps({'revision': anchor, 'timestamp': now,
            'operations': ops}, fmt=plistlib.FMT_XML)

    elif var == 4:
        # Variation 4: Full path in location, with media_type, binary plist
        desc = "Full path + media_type=8192, binary plist"
        ops = [
            {'operation': 'update_db_info', 'pid': 0, 'db_info': {
                'audio_language': 0, 'subtitle_language': 0, 'primary_container_pid': 0}},
            {'operation': 'insert_track', 'pid': asset_id, 'item': {
                'title': f'TinyTestV4', 'sort_name': f'tinytestv4',
                'total_time_ms': 125, 'media_kind': 1024,
                'media_type': 8192,
            }, 'track_info': {
                'location': device_path, 'file_size': file_size,
            }},
        ]
        return desc, plistlib.dumps({'revision': anchor, 'timestamp': now,
            'operations': ops}, fmt=plistlib.FMT_BINARY)

    elif var == 5:
        # Variation 5: No CIG, just the insert_track plist
        desc = "NO CIG — test if device accepts insert_track without signature"
        ops = [
            {'operation': 'insert_track', 'pid': asset_id, 'item': {
                'title': f'TinyTestV5', 'sort_name': f'tinytestv5',
                'total_time_ms': 125, 'media_kind': 1024,
            }, 'track_info': {
                'location': fname, 'base_location': base_loc,
                'file_size': file_size,
            }},
        ]
        return desc, plistlib.dumps({'revision': anchor, 'timestamp': now,
            'operations': ops}, fmt=plistlib.FMT_XML)

    elif var == 6:
        # Variation 6: insert_track at /iTunes_Control/Music/Sync/ path (no CIG needed)
        desc = "Dataclass plist at /iTunes_Control/Music/Sync/ (no CIG)"
        ops = [
            {'operation': 'update_db_info', 'pid': 0, 'db_info': {
                'audio_language': 0, 'subtitle_language': 0, 'primary_container_pid': 0}},
            {'operation': 'insert_track', 'pid': asset_id, 'item': {
                'title': f'TinyTestV6', 'sort_name': f'tinytestv6',
                'total_time_ms': 125, 'media_kind': 1024,
                'media_type': 8192, 'in_my_library': 1,
            }, 'track_info': {
                'location': fname, 'base_location': base_loc,
                'file_size': file_size,
            }},
        ]
        return desc, plistlib.dumps({'revision': anchor, 'timestamp': now,
            'operations': ops}, fmt=plistlib.FMT_XML)

    else:
        raise ValueError(f"Unknown variation {var}")


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

with open(GRAPPA_PATH, 'rb') as f: grappa_bytes = f.read()

# ATC Handshake
p(f'\n=== VARIATION {VARIATION} ===')
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
p(f'  Anchor: {anchor} → {new_anchor}')

# Generate file placement
asset_id = random.randint(100000000000000000, 999999999999999999)
slot = f'F{random.randint(0,49):02d}'
fname = ''.join(random.choices(string.ascii_uppercase, k=4)) + '.mp4'
device_path = f'/iTunes_Control/Music/{slot}/{fname}'

desc, plist_data = make_plist_variation(VARIATION, new_anchor, asset_id, device_path, fname, slot, file_size)
p(f'  {desc}')
p(f'  Plist: {len(plist_data)}B, fmt={"binary" if plist_data[:6] == b"bplist" else "xml"}')

# CIG (skip for variation 5)
use_cig = VARIATION != 5
cig_bytes = compute_cig(device_grappa, plist_data) if use_cig else None
if cig_bytes:
    p(f'  CIG: {len(cig_bytes)}B')
elif use_cig:
    p(f'  CIG: FAILED')

# AFC upload
async def afc():
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.afc import AfcService
    ld = await create_using_usbmux()
    async with AfcService(ld) as a:
        try: await a.makedirs(f'/iTunes_Control/Music/{slot}')
        except: pass
        with open(VIDEO, 'rb') as f:
            await a.set_file_contents(device_path, f.read())
        p(f'  Video → {device_path}')

        if VARIATION == 6:
            # Write to /iTunes_Control/Music/Sync/ (no CIG)
            try: await a.makedirs('/iTunes_Control/Music/Sync')
            except: pass
            ppath = f'/iTunes_Control/Music/Sync/Sync_{new_anchor:08d}.plist'
            await a.set_file_contents(ppath, plist_data)
            p(f'  Plist → {ppath} (NO CIG)')
            # Also write a minimal media plist with CIG for the anchor
            media_plist = plistlib.dumps({
                'revision': new_anchor,
                'timestamp': datetime.datetime.now(datetime.timezone.utc),
                'operations': [
                    {'operation': 'update_db_info', 'pid': 0, 'db_info': {
                        'audio_language': 0, 'subtitle_language': 0, 'primary_container_pid': 0}},
                ]
            }, fmt=plistlib.FMT_XML)
            mcig = compute_cig(device_grappa, media_plist)
            try: await a.makedirs('/iTunes_Control/Sync/Media')
            except: pass
            mpath = f'/iTunes_Control/Sync/Media/Sync_{new_anchor:08d}.plist'
            await a.set_file_contents(mpath, media_plist)
            if mcig:
                await a.set_file_contents(mpath + '.cig', mcig)
            p(f'  Media plist+CIG → {mpath}')
        else:
            # Write to /iTunes_Control/Sync/Media/ with CIG
            try: await a.makedirs('/iTunes_Control/Sync/Media')
            except: pass
            ppath = f'/iTunes_Control/Sync/Media/Sync_{new_anchor:08d}.plist'
            await a.set_file_contents(ppath, plist_data)
            if cig_bytes:
                await a.set_file_contents(ppath + '.cig', cig_bytes)
            p(f'  Plist{"+CIG" if cig_bytes else ""} → {ppath}')

asyncio.run(afc())

# MetadataSyncFinished
p(f'\nMetadataSyncFinished (anchor={new_anchor})...')
ATH.ATHostConnectionSendMetadataSyncFinished(conn,
    cfdict(Keybag=cfnum32(1), Media=cfnum32(1)),
    cfdict(Media=cfnum32(new_anchor)))

# Read responses
p('\nReading responses...')
for i in range(15):
    msg, name = read_msg(conn, 10)
    if name in ['TIMEOUT', None]: p(f'  << {name}'); break
    p(f'  << {name}')
    CF.CFShow(msg)
    if name == 'AssetManifest': p('  *** ASSET MANIFEST! ***')
    if name == 'SyncFinished': break

ATH.ATHostConnectionInvalidate(conn)
ATH.ATHostConnectionRelease(conn)
p(f'\n=== VARIATION {VARIATION} DONE ===')
