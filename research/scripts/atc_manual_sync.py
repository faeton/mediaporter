#!/usr/bin/env python3
"""
FULLY MANUAL ATC sync — no ATHostConnection at all.
Uses raw com.apple.atc service connection + binary plist wire protocol.

Wire format: 4-byte LE length + binary plist
Message format: {Command, Params, Session, Type, Id}

Flow:
  1. Start com.apple.atc service
  2. Read device initial messages (Capabilities, InstalledAssets, AssetMetrics, SyncAllowed)
  3. Send HostInfo
  4. Send RequestingSync with replayed Grappa
  5. Read ReadyForSync
  6. Upload file via AFC
  7. Send FileBegin + file data + FileComplete on ATC
  8. Send MetadataSyncFinished
  9. Read AssetManifest → SyncFinished
"""
import asyncio, ctypes, signal, sys, os, random, string, plistlib, struct, time
from ctypes import (c_void_p, c_char_p, c_int, c_uint, c_long,
                    CFUNCTYPE, POINTER, byref, cast)

def p(msg): print(msg, flush=True)

# Frameworks
CF = ctypes.cdll.LoadLibrary('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
MD = ctypes.cdll.LoadLibrary('/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice')

kCFAllocatorDefault = c_void_p.in_dll(CF, 'kCFAllocatorDefault')
kCFRunLoopDefaultMode = c_void_p.in_dll(CF, 'kCFRunLoopDefaultMode')

CF.CFStringCreateWithCString.restype = c_void_p
CF.CFStringCreateWithCString.argtypes = [c_void_p, c_char_p, c_uint]
CF.CFStringGetCString.restype = ctypes.c_bool
CF.CFStringGetCString.argtypes = [c_void_p, c_char_p, c_int, c_uint]
CF.CFRunLoopRunInMode.restype = c_int
CF.CFRunLoopRunInMode.argtypes = [c_void_p, ctypes.c_double, ctypes.c_bool]

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
MD.AMDServiceConnectionSend.restype = c_long
MD.AMDServiceConnectionSend.argtypes = [c_void_p, c_char_p, c_long]
MD.AMDServiceConnectionReceive.restype = c_long
MD.AMDServiceConnectionReceive.argtypes = [c_void_p, c_char_p, c_long]

def cfstr(s): return CF.CFStringCreateWithCString(kCFAllocatorDefault, s.encode('utf-8'), 0x08000100)
def cfstr_to_str(cf):
    if not cf: return None
    buf = ctypes.create_string_buffer(4096)
    return buf.value.decode('utf-8') if CF.CFStringGetCString(cf, buf, 4096, 0x08000100) else None

# ============================================================
# Raw ATC wire protocol
# ============================================================
msg_id_counter = [0]

def atc_send(svc, command, params=None):
    """Send ATC message: 4-byte LE length + binary plist."""
    msg_id_counter[0] += 1
    msg = {
        'Command': command,
        'Params': params or {},
        'Session': 0,
        'Type': 0,
        'Id': msg_id_counter[0],
    }
    data = plistlib.dumps(msg, fmt=plistlib.FMT_BINARY)
    header = struct.pack('<I', len(data))
    total = header + data
    n = MD.AMDServiceConnectionSend(svc, total, len(total))
    p(f'  >> {command} (id={msg_id_counter[0]}, {n}B sent)')
    return n

def atc_recv(svc):
    """Receive one ATC message. Returns (command, params, full_msg) or (None, None, None)."""
    header = ctypes.create_string_buffer(4)
    n = MD.AMDServiceConnectionReceive(svc, header, 4)
    if n != 4:
        return None, None, None
    length = struct.unpack('<I', header.raw)[0]
    if length > 50_000_000:
        p(f'  !! Insane message length: {length}')
        return None, None, None

    body = bytearray(length)
    buf = (ctypes.c_char * length).from_buffer(body)
    received = 0
    while received < length:
        chunk = min(length - received, 65536)
        tmp = ctypes.create_string_buffer(chunk)
        n = MD.AMDServiceConnectionReceive(svc, tmp, chunk)
        if n <= 0:
            p(f'  !! Receive failed at {received}/{length}')
            return None, None, None
        body[received:received+n] = tmp.raw[:n]
        received += n

    msg = plistlib.loads(bytes(body))
    cmd = msg.get('Command', '?')
    params = msg.get('Params', {})
    p(f'  << {cmd} (id={msg.get("Id", "?")})')
    return cmd, params, msg

def atc_recv_until(svc, target, max_msgs=15):
    """Read messages until we see target command."""
    for _ in range(max_msgs):
        cmd, params, msg = atc_recv(svc)
        if cmd is None:
            return None, None
        if cmd == target:
            return params, msg
    return None, None

# ============================================================
VIDEO = sys.argv[1] if len(sys.argv) > 1 else 'test_fixtures/output/test_tiny_red.m4v'
file_size = os.path.getsize(VIDEO)
with open('traces/grappa.bin', 'rb') as f: grappa_bytes = f.read()

# Find device
p('Finding device...')
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

# Connect and start ATC service
p('\nConnecting...')
rc = MD.AMDeviceConnect(found[0])
p(f'  Connect: {rc}')
rc = MD.AMDeviceStartSession(found[0])
p(f'  StartSession: {rc}')

atc = c_void_p()
rc = MD.AMDeviceSecureStartService(found[0], cfstr('com.apple.atc'), None, byref(atc))
p(f'  StartService(com.apple.atc): rc={rc}')
if not atc.value: p('FAILED'); sys.exit(1)

# ============================================================
# [1] Read initial device messages
# ============================================================
p('\n[1] Reading device initial messages...')
# Device sends: Capabilities, InstalledAssets, AssetMetrics, SyncAllowed
for _ in range(6):
    cmd, params, msg = atc_recv(atc)
    if cmd is None: break
    if cmd == 'SyncAllowed':
        p(f'      ManualSync={params.get("ManualSync")}, AutoSync={params.get("AutoSync")}')
        if params.get('ManualSync') or params.get('AutoSync'):
            break  # Got the real SyncAllowed

# ============================================================
# [2] Send HostInfo + RequestingSync back-to-back (no waiting)
# ============================================================
p('\n[2] Sending HostInfo...')
atc_send(atc, 'HostInfo', {
    'HostInfo': {
        'LibraryID': 'MEDIAPORTER00001',
        'SyncHostName': 'm3max',
        'SyncedDataclasses': [],
        'Version': '12.8',
    },
    'LocalCloudSupport': 0,
})

p('\n[3] Sending RequestingSync with Grappa (immediately)...')
atc_send(atc, 'RequestingSync', {
    'DataclassAnchors': {'Media': 0},
    'Dataclasses': ['Media', 'Keybag'],
    'HostInfo': {
        'Grappa': grappa_bytes,
        'LibraryID': 'MEDIAPORTER00001',
        'SyncHostName': 'm3max',
        'SyncedDataclasses': [],
        'Version': '12.8',
    },
})

# Read all responses, handle Pings, wait for ReadyForSync
p('  Reading responses...')
device_grappa = None
anchor = 0
for _ in range(20):
    cmd, params, msg = atc_recv(atc)
    if cmd is None:
        p('  !! No more messages')
        break
    if cmd == 'Ping':
        # Respond to keep connection alive
        atc_send(atc, 'Ping', {})
        continue
    if cmd == 'IdleExit':
        p('  !! Device sent IdleExit — connection closing')
        break
    if cmd == 'SyncFailed':
        ec = params.get('ErrorCode', '?')
        p(f'  !! SyncFailed! ErrorCode={ec}')
        p(f'  !! Full: {params}')
        sys.exit(1)
    if cmd == 'ReadyForSync':
        di = params.get('DeviceInfo', {})
        dg = di.get('Grappa')
        if isinstance(dg, bytes):
            device_grappa = dg
            p(f'  Device Grappa: {len(device_grappa)} bytes')
        anchors = params.get('DataclassAnchors', {})
        a = anchors.get('Media', 0)
        anchor = int(a) if isinstance(a, (int, str)) else 0
        p(f'  Anchor: {anchor}')
        break

if not device_grappa:
    p('FAILED: No device Grappa'); sys.exit(1)

new_anchor = anchor + 1

# ============================================================
# [4] Upload file via AFC
# ============================================================
asset_id = random.randint(100000000000000000, 999999999999999999)
slot = f'F{random.randint(0,49):02d}'
fname = ''.join(random.choices(string.ascii_uppercase, k=4)) + '.mp4'
device_path = f'/iTunes_Control/Music/{slot}/{fname}'
p(f'\n[4] AFC upload: {device_path} (asset_id={asset_id})')

async def afc_upload():
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.afc import AfcService
    ld = await create_using_usbmux()
    async with AfcService(ld) as a:
        try: await a.makedirs(f'/iTunes_Control/Music/{slot}')
        except: pass
        with open(VIDEO, 'rb') as f:
            await a.set_file_contents(device_path, f.read())
        p(f'  Done: {device_path}')
asyncio.run(afc_upload())

# ============================================================
# [5] Write sync plists via AFC (so device knows about our assets)
# ============================================================
p(f'\n[5] Writing sync plists via AFC...')
import plistlib as pl, datetime

CIG_LIB = ctypes.cdll.LoadLibrary(os.path.join(os.path.dirname(__file__), 'cig', 'libcig.dylib'))
CIG_LIB.cig_calc.restype = c_int
CIG_LIB.cig_calc.argtypes = [c_char_p, c_char_p, c_int, c_char_p, POINTER(c_int)]

def compute_cig(grappa, plist_data):
    out = ctypes.create_string_buffer(21)
    olen = c_int(21)
    if CIG_LIB.cig_calc(grappa, plist_data, len(plist_data), out, byref(olen)) == 1:
        return out.raw[:olen.value]
    return None

# Media operations plist (CIG-signed) with insert_track
sync_plist = pl.dumps({
    'revision': new_anchor,
    'timestamp': datetime.datetime.now(datetime.timezone.utc),
    'operations': [
        {'operation': 'update_db_info', 'pid': 0, 'db_info': {
            'audio_language': 0, 'subtitle_language': 0, 'primary_container_pid': 0}},
        {'operation': 'insert_track', 'pid': asset_id, 'item': {
            'title': f'RawATC Test', 'sort_name': f'rawatc test',
            'total_time_ms': 125, 'media_kind': 1024,
        }, 'track_info': {'location': device_path, 'file_size': file_size}},
    ]
}, fmt=pl.FMT_XML)
cig_bytes = compute_cig(device_grappa, sync_plist)
p(f'  Plist: {len(sync_plist)}B, CIG: {len(cig_bytes) if cig_bytes else "FAIL"}B')

async def write_plists():
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.afc import AfcService
    ld = await create_using_usbmux()
    async with AfcService(ld) as a:
        try: await a.makedirs('/iTunes_Control/Sync/Media')
        except: pass
        ppath = f'/iTunes_Control/Sync/Media/Sync_{new_anchor:08d}.plist'
        await a.set_file_contents(ppath, sync_plist)
        if cig_bytes:
            await a.set_file_contents(ppath + '.cig', cig_bytes)
        p(f'  → {ppath} + .cig')
asyncio.run(write_plists())

# ============================================================
# [6] MetadataSyncFinished (tells device to read the plists)
# ============================================================
p(f'\n[6] MetadataSyncFinished (anchor={new_anchor})...')
atc_send(atc, 'MetadataSyncFinished', {
    'SyncTypes': {'Keybag': 1, 'Media': 1},
    'DataclassAnchors': {'Media': new_anchor},
})

# Read responses — handle Pings to keep connection alive
p('  Reading responses (handling Pings)...')
got_asset_manifest = False
for _ in range(20):
    cmd, params, msg = atc_recv(atc)
    if cmd is None:
        p('  (no more messages)')
        break
    if cmd == 'Ping':
        atc_send(atc, 'Ping', {})
        continue
    if cmd == 'IdleExit':
        p('  !! IdleExit')
        break
    if cmd == 'AssetManifest':
        p('  *** GOT ASSET MANIFEST! ***')
        p(f'  Assets: {params}')
        got_asset_manifest = True
        break
    if cmd == 'Progress':
        p(f'  Progress: {params.get("OverallProgress", "?")}')
        continue
    if cmd == 'SyncFinished':
        p('  SyncFinished (no AssetManifest)')
        break

# ============================================================
# [6] Send FileBegin / FileProgress / FileComplete
# ============================================================
if got_asset_manifest or True:  # Try regardless
    p(f'\n[7] FileBegin...')
    atc_send(atc, 'FileBegin', {
        'AssetID': asset_id,
        'Dataclass': 'Media',
        'FileSize': file_size,
        'TotalSize': file_size,
    })

    p(f'  FileProgress ({file_size}B)...')
    with open(VIDEO, 'rb') as f:
        video_data = f.read()
    CHUNK = 262144
    offset = 0
    while offset < len(video_data):
        chunk = video_data[offset:offset + CHUNK]
        atc_send(atc, 'FileProgress', {
            'AssetID': asset_id,
            'Dataclass': 'Media',
            'Data': chunk,
            'Progress': offset + len(chunk),
        })
        offset += len(chunk)

    p(f'  FileComplete...')
    atc_send(atc, 'FileComplete', {
        'AssetID': asset_id,
        'Dataclass': 'Media',
        'AssetPath': device_path,
    })

    # Read final responses
    p('\n[8] Final responses...')
    for _ in range(20):
        cmd, params, msg = atc_recv(atc)
        if cmd is None:
            p('  (no more messages)')
            break
        if cmd == 'Ping':
            atc_send(atc, 'Ping', {})
            continue
        if cmd == 'SyncFinished':
            p('  Sync finished!')
            break
        if cmd == 'AssetManifest':
            p(f'  AssetManifest: {params}')

p(f'\nDone — check TV app for {device_path}')
