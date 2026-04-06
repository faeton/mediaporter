#!/usr/bin/env python3
"""
ATC sync using go-tunes VIDEO format (from functional/video/).

Key differences from our previous attempts:
1. NO update_db_info — only insert_track
2. video_info dict (not track_info) with media_kind=1024
3. File path NOT in plist — device requests via AssetManifest
4. File sent via ATHostConnection file transfer after AssetManifest
"""
import asyncio, ctypes, signal, sys, os, random, string, plistlib, datetime
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
    ('ATHostConnectionSendPowerAssertion', c_int, [c_void_p, c_void_p]),
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
    if not anchors: return 0
    val = CF.CFDictionaryGetValue(anchors, cfstr('Media'))
    if not val: return 0
    if CF.CFGetTypeID(val) == CF.CFStringGetTypeID():
        return int(cfstr_to_str(val))
    return 0

# ============================================================
VIDEO = sys.argv[1] if len(sys.argv) > 1 else 'test_fixtures/output/test_tiny_red.m4v'
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
p(f'Device: {found[1][:16]}...')

with open('traces/grappa.bin', 'rb') as f: grappa_bytes = f.read()

# ============================================================
# [1] ATC Handshake
# ============================================================
p('\n[1] Handshake...')
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
anchor = extract_anchor(msg)
new_anchor = anchor + 1
p(f'  Grappa: {len(device_grappa)}B, anchor: {anchor} → {new_anchor}')

# ============================================================
# [2] Write go-tunes VIDEO format plist (NO update_db_info!)
# ============================================================
asset_id = random.randint(100000000000000000, 999999999999999999)
p(f'\n[2] Writing go-tunes video plist (asset_id={asset_id})...')

# go-tunes video format: insert_track with video_info, NO track_info, NO update_db_info
sync_plist = plistlib.dumps({
    'revision': new_anchor,
    'timestamp': datetime.datetime.now(datetime.timezone.utc),
    'operations': [
        {
            'operation': 'insert_track',
            'pid': asset_id,
            'item': {
                'title': 'MP Video Test',
                'sort_name': 'MP Video Test',
                'total_time_ms': 125,
                'file_size': file_size,
            },
            'video_info': {
                'media_kind': 1024,  # Home Video
            },
        },
    ],
}, fmt=plistlib.FMT_XML)

cig = compute_cig(device_grappa, sync_plist)
p(f'  Plist: {len(sync_plist)}B, CIG: {len(cig) if cig else "FAIL"}B')

# Print the plist for verification
p(f'  Content:\n{sync_plist.decode()[:800]}')

async def write_plist():
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.afc import AfcService
    ld = await create_using_usbmux()
    async with AfcService(ld) as a:
        try: await a.makedirs('/iTunes_Control/Sync/Media')
        except: pass
        ppath = f'/iTunes_Control/Sync/Media/Sync_{new_anchor:08d}.plist'
        await a.set_file_contents(ppath, sync_plist)
        if cig:
            await a.set_file_contents(ppath + '.cig', cig)
        p(f'  → {ppath} + .cig')
asyncio.run(write_plist())

# ============================================================
# [3] SendPowerAssertion + MetadataSyncFinished (go-tunes order)
# ============================================================
p(f'\n[3] SendPowerAssertion...')
# CFBoolean true = kCFBooleanTrue
kCFBooleanTrue = c_void_p.in_dll(CF, 'kCFBooleanTrue')
ATH.ATHostConnectionSendPowerAssertion(conn, kCFBooleanTrue)

p(f'  MetadataSyncFinished (anchor="{new_anchor}" as string)...')
# go-tunes passes anchor as STRING, not number!
ATH.ATHostConnectionSendMetadataSyncFinished(conn,
    cfdict(Keybag=cfnum32(1), Media=cfnum32(1)),
    cfdict(Media=cfstr(str(new_anchor))))

# ============================================================
# [4] Read responses — looking for AssetManifest!
# ============================================================
p('\n[4] Reading (looking for AssetManifest)...')
got_manifest = False
device_path = None
for i in range(20):
    msg, name = read_msg(conn, 15)
    if name in ['TIMEOUT', None]: p(f'  << {name}'); break
    p(f'  << {name}')
    CF.CFShow(msg)

    if name == 'AssetManifest':
        p('  *** GOT ASSET MANIFEST! ***')
        got_manifest = True

        # Upload file via AFC first
        slot = f'F{random.randint(0,49):02d}'
        fname = ''.join(random.choices(string.ascii_uppercase, k=4)) + '.mp4'
        device_path = f'/iTunes_Control/Music/{slot}/{fname}'
        p(f'\n  Uploading file via AFC to {device_path}...')

        async def upload():
            from pymobiledevice3.lockdown import create_using_usbmux
            from pymobiledevice3.services.afc import AfcService
            ld = await create_using_usbmux()
            async with AfcService(ld) as a:
                try: await a.makedirs(f'/iTunes_Control/Music/{slot}')
                except: pass
                with open(VIDEO, 'rb') as f:
                    await a.set_file_contents(device_path, f.read())
                p(f'  Uploaded: {device_path}')
        asyncio.run(upload())

        from ctypes import c_int64, c_uint32, c_float
        def cfnum64(v):
            val = c_int64(v); return CF.CFNumberCreate(kCFAllocatorDefault, 4, byref(val))

        # PATCH Grappa session ID so high-level API works
        GRAPPA_OFFSET = 0x5C
        conn_addr = ctypes.cast(conn, c_void_p).value
        grappa_ptr = ctypes.cast(conn_addr + GRAPPA_OFFSET, POINTER(c_uint32))
        p(f'  Patching Grappa at offset 0x5C: {grappa_ptr[0]} → 1')
        grappa_ptr[0] = 1

        # Declare high-level API functions
        ATH.ATHostConnectionSendFileBegin.restype = c_void_p
        ATH.ATHostConnectionSendFileBegin.argtypes = [c_void_p, c_void_p, c_void_p, c_void_p, c_void_p, c_void_p]
        ATH.ATHostConnectionSendAssetCompleted.restype = c_void_p
        ATH.ATHostConnectionSendAssetCompleted.argtypes = [c_void_p, c_void_p, c_void_p, c_void_p]

        # Try HIGH-LEVEL SendFileBegin (with patched Grappa)
        cfAID = cfnum64(asset_id)
        cfSz = cfnum64(file_size)
        p(f'  HIGH-LEVEL SendFileBegin...')
        rc = ATH.ATHostConnectionSendFileBegin(conn, cfAID, cfstr('Media'), cfSz, cfSz, cfSz)
        p(f'  >> SendFileBegin result={rc}')

        # HIGH-LEVEL SendAssetCompleted
        p(f'  HIGH-LEVEL SendAssetCompleted...')
        rc2 = ATH.ATHostConnectionSendAssetCompleted(conn, cfAID, cfstr('Media'), cfstr(device_path))
        p(f'  >> SendAssetCompleted result={rc2}')

    if name == 'SyncFinished':
        break

# ============================================================
# Cleanup
# ============================================================
ATH.ATHostConnectionInvalidate(conn)
ATH.ATHostConnectionRelease(conn)

if got_manifest:
    p(f'\n*** AssetManifest received! File at {device_path} ***')
    p('Check TV app!')
else:
    p('\nNo AssetManifest received.')
