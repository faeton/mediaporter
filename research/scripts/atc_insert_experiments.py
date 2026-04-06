#!/usr/bin/env python3
"""
Targeted insert_track experiments. Each experiment tests ONE hypothesis.
Usage: python scripts/atc_insert_experiments.py [experiment_number]
"""
import asyncio, ctypes, signal, sys, os, random, string, plistlib, datetime
from ctypes import (c_void_p, c_char_p, c_int, c_uint, c_long,
                    CFUNCTYPE, POINTER, byref, cast)

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

def do_handshake():
    """Full ATC handshake through ReadyForSync. Returns (conn, device_grappa, anchor)."""
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

    dg = extract_device_grappa(msg)
    anchor = extract_anchor(msg)
    p(f'  Grappa: {len(dg)}B, anchor: {anchor}')
    return conn, dg, anchor

# ============================================================

EXP = int(sys.argv[1]) if len(sys.argv) > 1 else 1
VIDEO = 'test_fixtures/output/test_tiny_red.m4v'
file_size = os.path.getsize(VIDEO)

p(f'\n{"="*60}')
p(f'  EXPERIMENT {EXP}')
p(f'{"="*60}')

conn, device_grappa, anchor = do_handshake()
new_anchor = anchor + 1
asset_id = random.randint(100000000000000000, 999999999999999999)
slot = f'F{random.randint(0,49):02d}'
fname = ''.join(random.choices(string.ascii_uppercase, k=4)) + '.mp4'
device_path = f'/iTunes_Control/Music/{slot}/{fname}'

async def write_afc(paths_data):
    """Write files to device via AFC. paths_data = [(remote_path, bytes), ...]"""
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.afc import AfcService
    ld = await create_using_usbmux()
    async with AfcService(ld) as a:
        for rpath, data in paths_data:
            # Ensure parent dir exists
            parent = '/'.join(rpath.split('/')[:-1])
            try: await a.makedirs(parent)
            except: pass
            await a.set_file_contents(rpath, data)
            p(f'  AFC → {rpath} ({len(data)}B)')

if EXP == 1:
    # ============================================================
    # EXP 1: ONLY dataclass plist at /iTunes_Control/Music/Sync/
    #         NO Media operations plist. See if device reads it.
    # ============================================================
    p(f'  Hypothesis: Device needs Music/Sync plist without Media plist')
    plist = plistlib.dumps({
        'revision': new_anchor,
        'timestamp': datetime.datetime.now(datetime.timezone.utc),
        'operations': [
            {'operation': 'update_db_info', 'pid': 0, 'db_info': {
                'audio_language': 0, 'subtitle_language': 0, 'primary_container_pid': 0}},
            {'operation': 'insert_track', 'pid': asset_id, 'item': {
                'title': f'Exp1Test', 'sort_name': f'exp1test',
                'total_time_ms': 125, 'media_kind': 1024,
            }, 'track_info': {'location': device_path, 'file_size': file_size}},
        ]
    }, fmt=plistlib.FMT_XML)

    with open(VIDEO, 'rb') as f: vdata = f.read()
    asyncio.run(write_afc([
        (device_path, vdata),
        (f'/iTunes_Control/Music/Sync/Sync_{new_anchor:08d}.plist', plist),
    ]))

elif EXP == 2:
    # ============================================================
    # EXP 2: CIG-signed plist with ONLY insert_track (no update_db_info)
    #         at /iTunes_Control/Sync/Media/
    # ============================================================
    p(f'  Hypothesis: update_db_info interferes with insert_track processing')
    plist = plistlib.dumps({
        'revision': new_anchor,
        'timestamp': datetime.datetime.now(datetime.timezone.utc),
        'operations': [
            {'operation': 'insert_track', 'pid': asset_id, 'item': {
                'title': f'Exp2Test', 'sort_name': f'exp2test',
                'total_time_ms': 125, 'media_kind': 1024,
            }, 'track_info': {'location': device_path, 'file_size': file_size}},
        ]
    }, fmt=plistlib.FMT_XML)
    cig = compute_cig(device_grappa, plist)

    with open(VIDEO, 'rb') as f: vdata = f.read()
    files = [
        (device_path, vdata),
        (f'/iTunes_Control/Sync/Media/Sync_{new_anchor:08d}.plist', plist),
    ]
    if cig: files.append((f'/iTunes_Control/Sync/Media/Sync_{new_anchor:08d}.plist.cig', cig))
    asyncio.run(write_afc(files))

elif EXP == 3:
    # ============================================================
    # EXP 3: go-tunes EXACT two-plist pattern adapted for Music
    #   Plist A: /iTunes_Control/Music/Sync/ with insert_track (NO CIG)
    #   Plist B: /iTunes_Control/Sync/Media/ with update_db_info only (WITH CIG)
    # ============================================================
    p(f'  Hypothesis: Need BOTH plists, insert_track in Music/Sync')
    plist_a = plistlib.dumps({
        'revision': new_anchor,
        'timestamp': datetime.datetime.now(datetime.timezone.utc),
        'operations': [
            {'operation': 'update_db_info', 'pid': 0, 'db_info': {
                'audio_language': 0, 'subtitle_language': 0, 'primary_container_pid': 0}},
            {'operation': 'insert_track', 'pid': asset_id, 'item': {
                'title': f'Exp3Test', 'sort_name': f'exp3test',
                'total_time_ms': 125, 'media_kind': 1024,
            }, 'track_info': {'location': device_path, 'file_size': file_size}},
        ]
    }, fmt=plistlib.FMT_XML)

    plist_b = plistlib.dumps({
        'revision': new_anchor,
        'timestamp': datetime.datetime.now(datetime.timezone.utc),
        'operations': [
            {'operation': 'update_db_info', 'pid': 0, 'db_info': {
                'audio_language': 0, 'subtitle_language': 0, 'primary_container_pid': 0}},
        ]
    }, fmt=plistlib.FMT_XML)
    cig = compute_cig(device_grappa, plist_b)

    with open(VIDEO, 'rb') as f: vdata = f.read()
    files = [
        (device_path, vdata),
        (f'/iTunes_Control/Music/Sync/Sync_{new_anchor:08d}.plist', plist_a),
        (f'/iTunes_Control/Sync/Media/Sync_{new_anchor:08d}.plist', plist_b),
    ]
    if cig: files.append((f'/iTunes_Control/Sync/Media/Sync_{new_anchor:08d}.plist.cig', cig))
    asyncio.run(write_afc(files))

elif EXP == 4:
    # ============================================================
    # EXP 4: insert_track with ringtone-style format (guid instead of location)
    #         in CIG-signed Media plist
    # ============================================================
    p(f'  Hypothesis: Video uses guid-based format like ringtones')
    guid = f'{random.randint(0, 0xFFFFFFFFFFFFFFFF):016X}'
    plist = plistlib.dumps({
        'revision': new_anchor,
        'timestamp': datetime.datetime.now(datetime.timezone.utc),
        'operations': [
            {'operation': 'update_db_info', 'pid': 0, 'db_info': {
                'audio_language': 0, 'subtitle_language': 0, 'primary_container_pid': 0}},
            {'operation': 'insert_track', 'pid': asset_id, 'item': {
                'title': f'Exp4Test', 'sort_name': f'exp4test',
                'total_time_ms': 125, 'media_kind': 1024,
            }, 'ringtone_info': {'guid': guid}},
        ]
    }, fmt=plistlib.FMT_XML)
    cig = compute_cig(device_grappa, plist)

    with open(VIDEO, 'rb') as f: vdata = f.read()
    files = [
        (device_path, vdata),
        (f'/iTunes_Control/Sync/Media/Sync_{new_anchor:08d}.plist', plist),
    ]
    if cig: files.append((f'/iTunes_Control/Sync/Media/Sync_{new_anchor:08d}.plist.cig', cig))
    asyncio.run(write_afc(files))

elif EXP == 5:
    # ============================================================
    # EXP 5: MetadataSyncFinished BEFORE writing plists
    #         Then write plists via AFC and wait longer
    # ============================================================
    p(f'  Hypothesis: Device needs MetadataSyncFinished first, then reads plists')

    # Send MetadataSyncFinished FIRST
    p(f'\n  MetadataSyncFinished (anchor={new_anchor})...')
    ATH.ATHostConnectionSendMetadataSyncFinished(conn,
        cfdict(Keybag=cfnum32(1), Media=cfnum32(1)),
        cfdict(Media=cfnum32(new_anchor)))

    # Read initial response
    msg, name = read_msg(conn, 3)
    if name: p(f'  << {name}')

    # NOW write plists
    plist = plistlib.dumps({
        'revision': new_anchor,
        'timestamp': datetime.datetime.now(datetime.timezone.utc),
        'operations': [
            {'operation': 'update_db_info', 'pid': 0, 'db_info': {
                'audio_language': 0, 'subtitle_language': 0, 'primary_container_pid': 0}},
            {'operation': 'insert_track', 'pid': asset_id, 'item': {
                'title': f'Exp5Test', 'sort_name': f'exp5test',
                'total_time_ms': 125, 'media_kind': 1024,
            }, 'track_info': {'location': device_path, 'file_size': file_size}},
        ]
    }, fmt=plistlib.FMT_XML)
    cig = compute_cig(device_grappa, plist)

    with open(VIDEO, 'rb') as f: vdata = f.read()
    files = [
        (device_path, vdata),
        (f'/iTunes_Control/Sync/Media/Sync_{new_anchor:08d}.plist', plist),
    ]
    if cig: files.append((f'/iTunes_Control/Sync/Media/Sync_{new_anchor:08d}.plist.cig', cig))
    asyncio.run(write_afc(files))

    # Read more responses (give device time)
    p('\n  Reading (waiting longer)...')
    for i in range(10):
        msg, name = read_msg(conn, 5)
        if name in ['TIMEOUT', None]: p(f'  << {name}'); break
        p(f'  << {name}')
        CF.CFShow(msg)
        if name == 'AssetManifest': p('  *** ASSET MANIFEST! ***')
        if name == 'SyncFinished': break
    ATH.ATHostConnectionInvalidate(conn)
    ATH.ATHostConnectionRelease(conn)
    p(f'\n=== EXP {EXP} DONE ===')
    sys.exit(0)

elif EXP == 6:
    # ============================================================
    # EXP 6: Binary plist format instead of XML
    # ============================================================
    p(f'  Hypothesis: Device expects binary plist, not XML')
    plist = plistlib.dumps({
        'revision': new_anchor,
        'timestamp': datetime.datetime.now(datetime.timezone.utc),
        'operations': [
            {'operation': 'update_db_info', 'pid': 0, 'db_info': {
                'audio_language': 0, 'subtitle_language': 0, 'primary_container_pid': 0}},
            {'operation': 'insert_track', 'pid': asset_id, 'item': {
                'title': f'Exp6Test', 'sort_name': f'exp6test',
                'total_time_ms': 125, 'media_kind': 1024,
            }, 'track_info': {'location': device_path, 'file_size': file_size}},
        ]
    }, fmt=plistlib.FMT_BINARY)
    cig = compute_cig(device_grappa, plist)

    with open(VIDEO, 'rb') as f: vdata = f.read()
    files = [
        (device_path, vdata),
        (f'/iTunes_Control/Sync/Media/Sync_{new_anchor:08d}.plist', plist),
    ]
    if cig: files.append((f'/iTunes_Control/Sync/Media/Sync_{new_anchor:08d}.plist.cig', cig))
    asyncio.run(write_afc(files))

elif EXP == 7:
    # ============================================================
    # EXP 7: Ringtone dataclass — test if insert_track works AT ALL
    #         Use "Ringtone" instead of "Media" in RequestingSync
    # ============================================================
    p(f'  Hypothesis: insert_track only works for Ringtone dataclass')
    p(f'  NOTE: This would need a different handshake — testing plist only')
    plist = plistlib.dumps({
        'revision': new_anchor,
        'timestamp': datetime.datetime.now(datetime.timezone.utc),
        'operations': [
            {'operation': 'update_db_info', 'pid': 0, 'db_info': {
                'audio_language': 0, 'subtitle_language': 0, 'primary_container_pid': 0}},
            {'operation': 'insert_track', 'pid': asset_id, 'item': {
                'title': f'Exp7Test', 'sort_name': f'exp7test',
                'total_time_ms': 125, 'media_kind': 32,  # 32 = ringtone
                'is_ringtone': True,
            }, 'ringtone_info': {'guid': f'{random.randint(0, 0xFFFFFFFFFFFFFFFF):016X}'}},
        ]
    }, fmt=plistlib.FMT_XML)
    cig = compute_cig(device_grappa, plist)

    files = [
        (f'/iTunes_Control/Sync/Media/Sync_{new_anchor:08d}.plist', plist),
    ]
    if cig: files.append((f'/iTunes_Control/Sync/Media/Sync_{new_anchor:08d}.plist.cig', cig))
    asyncio.run(write_afc(files))

else:
    p(f'Unknown experiment {EXP}. Available: 1-7')
    sys.exit(1)

# Common: MetadataSyncFinished + read responses (for EXPs 1-4, 6-7)
if EXP != 5:
    p(f'\nMetadataSyncFinished (anchor={new_anchor})...')
    ATH.ATHostConnectionSendMetadataSyncFinished(conn,
        cfdict(Keybag=cfnum32(1), Media=cfnum32(1)),
        cfdict(Media=cfnum32(new_anchor)))

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
    p(f'\n=== EXP {EXP} DONE ===')
