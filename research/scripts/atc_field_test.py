#!/usr/bin/env python3
"""
Test different insert_track field placements to find one that sets media_kind.
Creates multiple entries with different plist formats, then checks DB.
"""
import asyncio, ctypes, signal, sys, os, random, string, plistlib, datetime, sqlite3, tempfile, shutil
from ctypes import (c_void_p, c_char_p, c_int, c_uint, c_long,
                    c_int64, CFUNCTYPE, POINTER, byref, cast)

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
for fn, rt, at in [
    ('AMDeviceNotificationSubscribe', c_int, [AMDeviceNotificationCallback, c_uint, c_uint, c_void_p, POINTER(c_void_p)]),
    ('AMDeviceCopyDeviceIdentifier', c_void_p, [c_void_p]),
    ('AMDeviceRetain', c_void_p, [c_void_p]),
]:
    getattr(MD, fn).restype = rt; getattr(MD, fn).argtypes = at

for fn, rt, at in [
    ('ATHostConnectionCreateWithLibrary', c_void_p, [c_void_p, c_void_p, c_uint]),
    ('ATHostConnectionSendHostInfo', c_void_p, [c_void_p, c_void_p]),
    ('ATHostConnectionReadMessage', c_void_p, [c_void_p]),
    ('ATHostConnectionSendMessage', c_int, [c_void_p, c_void_p]),
    ('ATHostConnectionSendMetadataSyncFinished', c_void_p, [c_void_p, c_void_p, c_void_p]),
    ('ATHostConnectionSendPowerAssertion', c_void_p, [c_void_p, c_void_p]),
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
        if name in ['TIMEOUT', None]: return None, name
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
    if CF.CFGetTypeID(val) == CF.CFStringGetTypeID(): return cfstr_to_str(val)
    return '0'

# ============================================================
# Test variations for media_kind placement
# ============================================================
VARIATIONS = [
    # third-party tool actual values: media_type=2048, media_kind=2
    ("W1_reference_vals", {
        'operation': 'insert_track', 'pid': 0,
        'item': {'title': 'W1_reference_vals', 'sort_name': 'w1', 'total_time_ms': 125,
                 'file_size': 12497, 'media_kind': 2, 'media_type': 2048},
    }),
    ("W2_kind2_in_video_info", {
        'operation': 'insert_track', 'pid': 0,
        'item': {'title': 'W2_kind2_in_video_info', 'sort_name': 'w2', 'total_time_ms': 125,
                 'file_size': 12497},
        'video_info': {'media_kind': 2},
    }),
    ("W3_kind2_item_only", {
        'operation': 'insert_track', 'pid': 0,
        'item': {'title': 'W3_kind2_item_only', 'sort_name': 'w3', 'total_time_ms': 125,
                 'file_size': 12497, 'media_kind': 2},
    }),
    ("W4_type2048_item", {
        'operation': 'insert_track', 'pid': 0,
        'item': {'title': 'W4_type2048_item', 'sort_name': 'w4', 'total_time_ms': 125,
                 'file_size': 12497, 'media_type': 2048},
    }),
    ("W5_both_plus_loc", {
        'operation': 'insert_track', 'pid': 0,
        'item': {'title': 'W5_both_plus_loc', 'sort_name': 'w5', 'total_time_ms': 125,
                 'file_size': 12497, 'media_kind': 2, 'media_type': 2048,
                 'location_kind_id': 4},
    }),
    ("W6_track_info_reference", {
        'operation': 'insert_track', 'pid': 0,
        'item': {'title': 'W6_track_info_reference', 'sort_name': 'w6', 'total_time_ms': 125,
                 'file_size': 12497},
        'track_info': {'media_kind': 2, 'media_type': 2048, 'location_kind_id': 4},
    }),
]

file_size = 12497
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

with open('traces/grappa.bin', 'rb') as f: grappa_bytes = f.read()

# Handshake
p('Handshake...')
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
if not msg: p('FAILED'); sys.exit(1)

device_grappa = extract_device_grappa(msg)
anchor = int(extract_anchor(msg))
p(f'Ready. Anchor={anchor}')

# Create all variations in one plist
new_anchor = anchor + 1
operations = []
asset_ids = {}
for title, op_template in VARIATIONS:
    aid = random.randint(100000000000000000, 999999999999999999)
    op = dict(op_template)
    op['pid'] = aid
    asset_ids[title] = aid
    operations.append(op)
    p(f'  {title}: pid={aid}')

sync_plist = plistlib.dumps({
    'revision': new_anchor,
    'timestamp': datetime.datetime.now(datetime.timezone.utc),
    'operations': operations,
}, fmt=plistlib.FMT_XML)
cig = compute_cig(device_grappa, sync_plist)
p(f'Plist: {len(sync_plist)}B with {len(operations)} operations')

# Upload plist + dummy files
async def upload():
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.afc import AfcService
    ld = await create_using_usbmux()
    async with AfcService(ld) as a:
        try: await a.makedirs('/iTunes_Control/Sync/Media')
        except: pass
        ppath = f'/iTunes_Control/Sync/Media/Sync_{new_anchor:08d}.plist'
        await a.set_file_contents(ppath, sync_plist)
        if cig: await a.set_file_contents(ppath + '.cig', cig)
        p(f'  Plist → {ppath}')
asyncio.run(upload())

# MetadataSyncFinished
ATH.ATHostConnectionSendPowerAssertion(conn, kCFBooleanTrue)
ATH.ATHostConnectionSendMetadataSyncFinished(conn,
    cfdict(Keybag=cfnum32(1), Media=cfnum32(1)),
    cfdict(Media=cfstr(str(new_anchor))))

# Read AssetManifest
p('Reading...')
for i in range(10):
    msg, name = read_msg(conn, 15)
    if not name or name == 'TIMEOUT': break
    p(f'  << {name}')
    if name == 'AssetManifest':
        p('  *** AssetManifest! ***')
        # Send FileError for all assets (we don't need actual transfer)
        for title, aid in asset_ids.items():
            ATH.ATHostConnectionSendMessage(conn, ATH.ATCFMessageCreate(0, cfstr('FileError'),
                cfdict(AssetID=cfstr(str(aid)), Dataclass=cfstr('Media'), ErrorCode=cfnum32(0))))
        break
    if name == 'SyncFinished': break

# Read until SyncFinished
for i in range(10):
    msg, name = read_msg(conn, 10)
    if not name or name == 'TIMEOUT': break
    p(f'  << {name}')
    if name == 'SyncFinished':
        p('  *** SYNC COMPLETE! ***')
        break

ATH.ATHostConnectionInvalidate(conn)
ATH.ATHostConnectionRelease(conn)

# Now check DB for our entries
import time
time.sleep(2)
p('\n=== Checking DB ===')
async def check():
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.afc import AfcService
    ld = await create_using_usbmux()
    async with AfcService(ld) as a:
        tmp = tempfile.mkdtemp()
        db_path = f'{tmp}/MediaLibrary.sqlitedb'
        open(db_path, 'wb').write(await a.get_file_contents('/iTunes_Control/iTunes/MediaLibrary.sqlitedb'))
        try: open(f'{db_path}-wal', 'wb').write(await a.get_file_contents('/iTunes_Control/iTunes/MediaLibrary.sqlitedb-wal'))
        except: pass
        try: open(f'{db_path}-shm', 'wb').write(await a.get_file_contents('/iTunes_Control/iTunes/MediaLibrary.sqlitedb-shm'))
        except: pass
        db = sqlite3.connect(db_path)
        db.execute('PRAGMA wal_checkpoint(PASSIVE)')
        for title, aid in asset_ids.items():
            rows = list(db.execute('''
                SELECT ie.title, i.media_type, ie.media_kind, ie.location
                FROM item i JOIN item_extra ie ON i.item_pid = ie.item_pid
                WHERE ie.title = ?
            ''', (title,)))
            if rows:
                r = rows[0]
                status = "✓ VIDEO" if r[1] == 8192 or r[2] == 1024 else f"media_type={r[1]}, kind={r[2]}"
                p(f'  {title}: {status}')
            else:
                p(f'  {title}: NOT IN DB')
        db.close()
        shutil.rmtree(tmp)
asyncio.run(check())
