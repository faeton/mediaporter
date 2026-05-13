#!/usr/bin/env python3
"""
ATC video sync to iPad TV app using pymobiledevice3 for AFC.

Key protocol details (from wire capture):
1. MetadataSyncFinished wire command = "FinishedSyncingMetadata" (NOT "MetadataSyncFinished")
2. All anchors/AssetIDs are STRINGS on wire
3. SendPowerAssertion required before MetadataSyncFinished
4. go-tunes video plist format (video_info, no update_db_info)
5. Notification proxy ObserveNotification for com.apple.atc.idlewake
6. File uploaded via AFC, then registered via patched high-level API

Two-phase approach:
  Phase 1: Get AssetManifest (sync plist + CIG + correct MetadataSyncFinished)
  Phase 2: Transfer file (AFC upload + patched Grappa SendFileBegin/SendAssetCompleted)
"""
import asyncio, ctypes, signal, sys, os, random, string, plistlib, datetime, struct
from ctypes import (c_void_p, c_char_p, c_int, c_uint, c_long,
                    c_int64, c_uint32, c_float, CFUNCTYPE, POINTER, byref, cast)

def p(msg): print(msg, flush=True)
def timeout_handler(signum, frame): raise TimeoutError()
signal.signal(signal.SIGALRM, timeout_handler)

CF = ctypes.cdll.LoadLibrary('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
MD = ctypes.cdll.LoadLibrary('/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice')
ATH = ctypes.cdll.LoadLibrary('/System/Library/PrivateFrameworks/AirTrafficHost.framework/AirTrafficHost')
CIG_LIB = ctypes.cdll.LoadLibrary(os.path.join(os.path.dirname(__file__), 'cig', 'libcig.dylib'))
CIG_LIB.cig_calc.restype = c_int
CIG_LIB.cig_calc.argtypes = [c_char_p, c_char_p, c_int, c_char_p, POINTER(c_int)]

kCFAllocatorDefault = c_void_p.in_dll(CF, 'kCFAllocatorDefault')
kCFTypeDictionaryKeyCallBacks = c_void_p.in_dll(CF, 'kCFTypeDictionaryKeyCallBacks')
kCFTypeDictionaryValueCallBacks = c_void_p.in_dll(CF, 'kCFTypeDictionaryValueCallBacks')
kCFTypeArrayCallBacks = c_void_p.in_dll(CF, 'kCFTypeArrayCallBacks')
kCFRunLoopDefaultMode = c_void_p.in_dll(CF, 'kCFRunLoopDefaultMode')
kCFBooleanTrue = c_void_p.in_dll(CF, 'kCFBooleanTrue')

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
    ('ATHostConnectionSendMetadataSyncFinished', c_void_p, [c_void_p, c_void_p, c_void_p]),
    ('ATHostConnectionSendPowerAssertion', c_void_p, [c_void_p, c_void_p]),
    ('ATHostConnectionSendFileBegin', c_void_p, [c_void_p, c_void_p, c_void_p, c_void_p, c_void_p, c_void_p]),
    ('ATHostConnectionSendFileProgress', c_void_p, [c_void_p, c_void_p, c_void_p, c_int, ctypes.c_float, c_int]),
    ('ATHostConnectionSendAssetCompleted', c_void_p, [c_void_p, c_void_p, c_void_p, c_void_p]),
    ('ATHostConnectionGetGrappaSessionId', c_int, [c_void_p]),
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
def cfnum64(v):
    val = ctypes.c_int64(v); return CF.CFNumberCreate(kCFAllocatorDefault, 4, byref(val))
def cfdict(**kwargs):
    d = CF.CFDictionaryCreateMutable(kCFAllocatorDefault, 0, kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks)
    for k, v in kwargs.items(): CF.CFDictionarySetValue(d, cfstr(k), v)
    return d
def read_msg(conn, to=15):
    signal.alarm(to)
    try:
        msg = ATH.ATHostConnectionReadMessage(conn)
        signal.alarm(0)
        if not msg: return None, None
        return msg, cfstr_to_str(ATH.ATCFMessageGetName(msg))
    except TimeoutError:
        signal.alarm(0)
        return None, 'TIMEOUT'
def read_until(conn, target, max_msgs=10, to=8):
    for _ in range(max_msgs):
        msg, name = read_msg(conn, to)
        if name in ['TIMEOUT', None]: p(f'  << {name}'); return None, name
        p(f'  << {name}')
        if name == target: return msg, name
    return None, 'MAX_MSGS'
def compute_cig(grappa, plist_data):
    out = ctypes.create_string_buffer(21)
    olen = c_int(21)
    if CIG_LIB.cig_calc(grappa, plist_data, len(plist_data), out, byref(olen)) == 1:
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
    if not anchors: return '0'
    val = CF.CFDictionaryGetValue(anchors, cfstr('Media'))
    if not val: return '0'
    if CF.CFGetTypeID(val) == CF.CFStringGetTypeID():
        return cfstr_to_str(val)
    return '0'

# ============================================================
VIDEO = sys.argv[1] if len(sys.argv) > 1 else 'test_fixtures/output/test_tiny_red.m4v'
TITLE = sys.argv[2] if len(sys.argv) > 2 else 'MP Proper Test'
file_size = os.path.getsize(VIDEO)

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
p(f'Device: {found[1][:16]}..., file: {VIDEO} ({file_size}B)')

with open('traces/grappa.bin', 'rb') as f: grappa_bytes = f.read()

# ============================================================
# [1] ATC Handshake
# ============================================================
p('\n[1] ATC Handshake...')
conn = ATH.ATHostConnectionCreateWithLibrary(cfstr('com.mediaporter.sync'), cfstr(found[1]), 0)
conn_addr = ctypes.cast(conn, c_void_p).value

# SendHostInfo (LibraryID, SyncHostName, SyncedDataclasses, Version)
ATH.ATHostConnectionSendHostInfo(conn, cfdict(
    LibraryID=cfstr('MEDIAPORTER00001'), SyncHostName=cfstr('m3max'),
    SyncedDataclasses=CF.CFArrayCreateMutable(kCFAllocatorDefault, 0, kCFTypeArrayCallBacks),
    Version=cfstr('12.8')))
read_until(conn, 'SyncAllowed')

# RequestingSync with Grappa
grappa_cf = CF.CFDataCreate(kCFAllocatorDefault, grappa_bytes, len(grappa_bytes))
hi = cfdict(Grappa=grappa_cf, LibraryID=cfstr('MEDIAPORTER00001'), SyncHostName=cfstr('m3max'),
    SyncedDataclasses=CF.CFArrayCreateMutable(kCFAllocatorDefault, 0, kCFTypeArrayCallBacks), Version=cfstr('12.8'))
dc = CF.CFArrayCreateMutable(kCFAllocatorDefault, 0, kCFTypeArrayCallBacks)
CF.CFArrayAppendValue(dc, cfstr('Media'))
CF.CFArrayAppendValue(dc, cfstr('Keybag'))
# Anchor must be STRING '0'
ATH.ATHostConnectionSendMessage(conn, ATH.ATCFMessageCreate(0, cfstr('RequestingSync'),
    cfdict(DataclassAnchors=cfdict(Media=cfstr('0')), Dataclasses=dc, HostInfo=hi)))

msg, _ = read_until(conn, 'ReadyForSync')
if not msg: p('FAILED: No ReadyForSync'); sys.exit(1)

device_grappa = extract_device_grappa(msg)
anchor_str = extract_anchor(msg)
new_anchor = str(int(anchor_str) + 1)
p(f'  Device Grappa: {len(device_grappa)}B, anchor: {anchor_str} → {new_anchor}')

# ============================================================
# [2] Write sync plist (go-tunes video format + CIG)
# ============================================================
asset_id = random.randint(100000000000000000, 999999999999999999)
slot = f'F{random.randint(0,49):02d}'
fname = ''.join(random.choices(string.ascii_uppercase, k=4)) + '.mp4'
device_path = f'/iTunes_Control/Music/{slot}/{fname}'
p(f'\n[2] Sync plist: asset_id={asset_id}, path={device_path}')

# insert_track plist format (decoded from AFC trace)
now = datetime.datetime.now()  # naive datetime for binary plist compat
sync_plist = plistlib.dumps({
    'revision': int(new_anchor),
    'timestamp': now,
    'operations': [
        {
            'operation': 'update_db_info',
            'pid': random.randint(100000000000000000, 999999999999999999),
            'db_info': {
                'subtitle_language': -1,
                'primary_container_pid': 0,
                'audio_language': -1,
            },
        },
        {
            'operation': 'insert_track',
            'pid': asset_id,
            'item': {
                'title': TITLE,
                'sort_name': TITLE.lower(),
                'total_time_ms': 125,
                'date_created': now,
                'date_modified': now,
                'is_movie': True,              # ← THE KEY FIELD!
                'remember_bookmark': True,
            },
            'location': {
                'kind': 'MPEG-4 video file',   # ← file type descriptor
            },
            'video_info': {
                'has_alternate_audio': False,
                'is_anamorphic': False,
                'has_subtitles': False,
                'is_hd': False,
                'is_compressed': False,
                'has_closed_captions': False,
                'is_self_contained': False,
                'characteristics_valid': False,
            },
            'avformat_info': {
                'bit_rate': 160,
                'audio_format': 502,
                'channels': 2,
            },
            'item_stats': {
                'has_been_played': False,
                'play_count_recent': 0,
                'play_count_user': 0,
                'skip_count_user': 0,
                'skip_count_recent': 0,
            },
        },
    ],
}, fmt=plistlib.FMT_BINARY)  # Must be binary plist
cig = compute_cig(device_grappa, sync_plist)
p(f'  Plist: {len(sync_plist)}B, CIG: {len(cig)}B')

async def write_plist_and_file():
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.afc import AfcService
    ld = await create_using_usbmux()
    async with AfcService(ld) as a:
        # Write sync plist + CIG
        try: await a.makedirs('/iTunes_Control/Sync/Media')
        except: pass
        ppath = f'/iTunes_Control/Sync/Media/Sync_{int(new_anchor):08d}.plist'
        await a.set_file_contents(ppath, sync_plist)
        if cig: await a.set_file_contents(ppath + '.cig', cig)
        p(f'  Plist+CIG → {ppath}')
asyncio.run(write_plist_and_file())

# File will be written to /Airlock/Media/<AssetID> AFTER AssetManifest
# PowerAssertion + MetadataSyncFinished

# ============================================================
# [3] SendPowerAssertion + MetadataSyncFinished
# ============================================================
p(f'\n[3] PowerAssertion + MetadataSyncFinished...')
ATH.ATHostConnectionSendPowerAssertion(conn, kCFBooleanTrue)

# MetadataSyncFinished with STRING anchor
ATH.ATHostConnectionSendMetadataSyncFinished(conn,
    cfdict(Keybag=cfnum32(1), Media=cfnum32(1)),
    cfdict(Media=cfstr(new_anchor)))

# ============================================================
# [4] Read for AssetManifest
# ============================================================
p('\n[4] Reading for AssetManifest...')
got_manifest = False
manifest_assets = []
for i in range(20):
    msg, name = read_msg(conn, 15)
    if name in ['TIMEOUT', None]: p(f'  << {name}'); break
    p(f'  << {name}')
    if name not in ('Ping', 'Pong'):
        CF.CFShow(msg)

    if name == 'AssetManifest':
        p('  *** GOT ASSET MANIFEST! ***')
        got_manifest = True
        # Extract ALL asset IDs from manifest for handling stale ones
        CF.CFShow(msg)
        break
    if name == 'SyncFinished':
        p('  SyncFinished (no AssetManifest)')
        break

if not got_manifest:
    p('\nNo AssetManifest. Exiting.')
    ATH.ATHostConnectionInvalidate(conn)
    ATH.ATHostConnectionRelease(conn)
    sys.exit(1)

# ============================================================
# [5] Write file to /Airlock/Media/<AssetID> (staging path)
#     + send FileBegin/FileComplete via raw ATCFMessages
# ============================================================
p(f'\n[5] File transfer to /Airlock/Media/ staging...')
str_asset_id = str(asset_id)
airlock_path = f'/Airlock/Media/{str_asset_id}'

async def upload_files():
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.afc import AfcService
    ld = await create_using_usbmux()
    async with AfcService(ld) as a:
        with open(VIDEO, 'rb') as f:
            video_data = f.read()
        # Write to Airlock staging (for device to process media type)
        try: await a.makedirs('/Airlock/Media')
        except: pass
        try: await a.makedirs('/Airlock/Media/Artwork')
        except: pass
        await a.set_file_contents(airlock_path, video_data)
        p(f'  Video → {airlock_path} (staging)')
        # ALSO write to final path (for playback)
        try: await a.makedirs(f'/iTunes_Control/Music/{slot}')
        except: pass
        await a.set_file_contents(device_path, video_data)
        p(f'  Video → {device_path} (final)')
asyncio.run(upload_files())

# Send FileBegin (AssetID as STRING)
p(f'  FileBegin...')
fb = ATH.ATCFMessageCreate(0, cfstr('FileBegin'), cfdict(
    AssetID=cfstr(str_asset_id),
    FileSize=cfnum64(file_size),
    TotalSize=cfnum64(file_size),
    Dataclass=cfstr('Media')))
ATH.ATHostConnectionSendMessage(conn, fb)

# FileProgress (100%)
progress_val = ctypes.c_double(1.0)
cfP = CF.CFNumberCreate(kCFAllocatorDefault, 13, byref(progress_val))
fp = ATH.ATCFMessageCreate(0, cfstr('FileProgress'), cfdict(
    AssetID=cfstr(str_asset_id),
    AssetProgress=cfP, OverallProgress=cfP,
    Dataclass=cfstr('Media')))
ATH.ATHostConnectionSendMessage(conn, fp)

# FileComplete with FINAL path (/iTunes_Control/Music/Fxx/name.mp4)
p(f'  FileComplete(path={device_path})...')
fc = ATH.ATCFMessageCreate(0, cfstr('FileComplete'), cfdict(
    AssetID=cfstr(str_asset_id),
    AssetPath=cfstr(device_path),
    Dataclass=cfstr('Media')))
ATH.ATHostConnectionSendMessage(conn, fc)

# Send FileError for ALL other pending assets (stale from previous runs)
# These accumulate in AssetManifest until handled
KNOWN_STALE = ['977648489922361013', '559399545392434047',
               '469318257045849614', '258842043854441225',
               '891900328663897312', '765853979029746660',
               '171215612272209090', '838986371258311098',
               '356267630934910510', '596157304833630760',
               '588681793591071659', '4543310759494544838']
p(f'  Sending FileError for stale assets...')
for stale_id in KNOWN_STALE:
    if stale_id != str_asset_id:
        ATH.ATHostConnectionSendMessage(conn, ATH.ATCFMessageCreate(0, cfstr('FileError'),
            cfdict(AssetID=cfstr(stale_id), Dataclass=cfstr('Media'), ErrorCode=cfnum32(0))))

# ============================================================
# [6] Read final responses
# ============================================================
p('\n[6] Reading final responses...')
for i in range(15):
    msg, name = read_msg(conn, 10)
    if name in ['TIMEOUT', None]: p(f'  << {name}'); break
    p(f'  << {name}')
    CF.CFShow(msg)
    if name == 'SyncFinished':
        p('  *** SYNC COMPLETE! ***')
        break

ATH.ATHostConnectionInvalidate(conn)
ATH.ATHostConnectionRelease(conn)
p(f'\nDone! File: {device_path}, Title: "{TITLE}"')
p('Check TV app!')
