#!/usr/bin/env python3
"""
Zero-dependency ATC video sync — no pymobiledevice3.
Uses only Apple private frameworks via ctypes + stdlib.

Frameworks used:
  - CoreFoundation.framework (CF types)
  - MobileDevice.framework (device discovery + AFC file operations)
  - AirTrafficHost.framework (ATC protocol)
  - libcig.dylib (CIG signatures, compiled from go-tunes)
"""
import ctypes, signal, sys, os, random, string, plistlib, datetime
from ctypes import (c_void_p, c_char_p, c_int, c_uint, c_long,
                    c_int64, c_uint32, CFUNCTYPE, POINTER, byref, cast)

def p(msg): print(msg, flush=True)
def timeout_handler(signum, frame): raise TimeoutError()
signal.signal(signal.SIGALRM, timeout_handler)

# ============================================================
# Load frameworks
# ============================================================
CF = ctypes.cdll.LoadLibrary('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
MD = ctypes.cdll.LoadLibrary('/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice')
ATH = ctypes.cdll.LoadLibrary('/System/Library/PrivateFrameworks/AirTrafficHost.framework/AirTrafficHost')
CIG_LIB = ctypes.cdll.LoadLibrary(os.path.join(os.path.dirname(__file__), 'cig', 'libcig.dylib'))
CIG_LIB.cig_calc.restype = c_int
CIG_LIB.cig_calc.argtypes = [c_char_p, c_char_p, c_int, c_char_p, POINTER(c_int)]

# ============================================================
# CoreFoundation setup
# ============================================================
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

# ============================================================
# MobileDevice setup (device + AFC)
# ============================================================
AMDeviceNotificationCallback = CFUNCTYPE(None, c_void_p, c_void_p)
for fn, rt, at in [
    ('AMDeviceNotificationSubscribe', c_int, [AMDeviceNotificationCallback, c_uint, c_uint, c_void_p, POINTER(c_void_p)]),
    ('AMDeviceCopyDeviceIdentifier', c_void_p, [c_void_p]),
    ('AMDeviceRetain', c_void_p, [c_void_p]),
    ('AMDeviceConnect', c_int, [c_void_p]),
    ('AMDeviceStartSession', c_int, [c_void_p]),
    ('AMDeviceStartService', c_int, [c_void_p, c_void_p, POINTER(c_void_p), c_void_p]),
    ('AMDeviceDisconnect', c_int, [c_void_p]),
    # AFC functions
    ('AFCConnectionOpen', c_int, [c_void_p, c_uint, POINTER(c_void_p)]),
    ('AFCConnectionClose', c_int, [c_void_p]),
    ('AFCDirectoryCreate', c_int, [c_void_p, c_char_p]),
    ('AFCFileRefOpen', c_int, [c_void_p, c_char_p, c_int, POINTER(c_long)]),
    ('AFCFileRefWrite', c_int, [c_void_p, c_long, c_char_p, c_long]),
    ('AFCFileRefClose', c_int, [c_void_p, c_long]),
    ('AFCRemovePath', c_int, [c_void_p, c_char_p]),
]:
    getattr(MD, fn).restype = rt; getattr(MD, fn).argtypes = at

# ============================================================
# AirTrafficHost setup
# ============================================================
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

# ============================================================
# Helpers
# ============================================================
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
    if CF.CFGetTypeID(val) == CF.CFStringGetTypeID(): return cfstr_to_str(val)
    return '0'

# ============================================================
# AFC helper using MobileDevice.framework directly
# ============================================================
class NativeAFC:
    """AFC client using MobileDevice.framework — zero external dependencies."""

    def __init__(self, device):
        self.device = device
        self.afc_conn = None
        self._connect()

    def _connect(self):
        rc = MD.AMDeviceConnect(self.device)
        if rc != 0: raise RuntimeError(f'AMDeviceConnect failed: {rc}')
        rc = MD.AMDeviceStartSession(self.device)
        if rc != 0: raise RuntimeError(f'AMDeviceStartSession failed: {rc}')
        svc_handle = c_void_p()
        rc = MD.AMDeviceStartService(self.device, cfstr('com.apple.afc'), byref(svc_handle), None)
        if rc != 0: raise RuntimeError(f'StartService(afc) failed: {rc}')
        self.afc_conn = c_void_p()
        rc = MD.AFCConnectionOpen(svc_handle, 0, byref(self.afc_conn))
        if rc != 0: raise RuntimeError(f'AFCConnectionOpen failed: {rc}')
        p(f'  AFC connected')

    def makedirs(self, path):
        """Create directory (ignores errors if exists)."""
        MD.AFCDirectoryCreate(self.afc_conn, path.encode('utf-8'))

    def write_file(self, path, data):
        """Write bytes to a file on the device."""
        handle = c_long(0)
        rc = MD.AFCFileRefOpen(self.afc_conn, path.encode('utf-8'), 2, byref(handle))  # 2 = write
        if rc != 0:
            raise RuntimeError(f'AFCFileRefOpen({path}) failed: {rc}')
        # Write in chunks
        CHUNK = 1048576  # 1MB
        offset = 0
        while offset < len(data):
            chunk = data[offset:offset + CHUNK]
            rc = MD.AFCFileRefWrite(self.afc_conn, handle, chunk, len(chunk))
            if rc != 0:
                MD.AFCFileRefClose(self.afc_conn, handle)
                raise RuntimeError(f'AFCFileRefWrite failed: {rc}')
            offset += len(chunk)
        MD.AFCFileRefClose(self.afc_conn, handle)

    def close(self):
        if self.afc_conn:
            MD.AFCConnectionClose(self.afc_conn)
            self.afc_conn = None

# ============================================================
# Main
# ============================================================
VIDEO = sys.argv[1] if len(sys.argv) > 1 else 'test_fixtures/output/test_tiny_red.m4v'
TITLE = sys.argv[2] if len(sys.argv) > 2 else 'NoDeps Test'
file_size = os.path.getsize(VIDEO)
with open(VIDEO, 'rb') as f: video_data = f.read()

GRAPPA_PATH = os.path.join(os.path.dirname(__file__), '..', 'traces', 'grappa.bin')
with open(GRAPPA_PATH, 'rb') as f: grappa_bytes = f.read()

# [1] Find device
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
if not found[0]: p('No device found'); sys.exit(1)
p(f'Device: {found[1][:16]}...')

# [2] ATC Handshake
p('\n[2] ATC Handshake...')
conn = ATH.ATHostConnectionCreateWithLibrary(cfstr('com.mediaporter.sync'), cfstr(found[1]), 0)

ATH.ATHostConnectionSendHostInfo(conn, cfdict(
    LibraryID=cfstr('MEDIAPORTER00001'), SyncHostName=cfstr('mediaporter'),
    SyncedDataclasses=CF.CFArrayCreateMutable(kCFAllocatorDefault, 0, kCFTypeArrayCallBacks),
    Version=cfstr('12.8')))
read_until(conn, 'SyncAllowed')

grappa_cf = CF.CFDataCreate(kCFAllocatorDefault, grappa_bytes, len(grappa_bytes))
hi = cfdict(Grappa=grappa_cf, LibraryID=cfstr('MEDIAPORTER00001'), SyncHostName=cfstr('mediaporter'),
    SyncedDataclasses=CF.CFArrayCreateMutable(kCFAllocatorDefault, 0, kCFTypeArrayCallBacks), Version=cfstr('12.8'))
dc = CF.CFArrayCreateMutable(kCFAllocatorDefault, 0, kCFTypeArrayCallBacks)
CF.CFArrayAppendValue(dc, cfstr('Media'))
CF.CFArrayAppendValue(dc, cfstr('Keybag'))
ATH.ATHostConnectionSendMessage(conn, ATH.ATCFMessageCreate(0, cfstr('RequestingSync'),
    cfdict(DataclassAnchors=cfdict(Media=cfstr('0')), Dataclasses=dc, HostInfo=hi)))

msg, _ = read_until(conn, 'ReadyForSync')
if not msg: p('FAILED: No ReadyForSync'); sys.exit(1)

device_grappa = extract_device_grappa(msg)
anchor_str = extract_anchor(msg)
new_anchor = str(int(anchor_str) + 1)
p(f'  Grappa: {len(device_grappa)}B, anchor: {anchor_str} → {new_anchor}')

# [3] Build sync plist + CIG
asset_id = random.randint(100000000000000000, 999999999999999999)
slot = f'F{random.randint(0,49):02d}'
fname = ''.join(random.choices(string.ascii_uppercase, k=4)) + '.mp4'
device_path = f'/iTunes_Control/Music/{slot}/{fname}'
p(f'\n[3] Building plist: asset={asset_id}, path={device_path}')

now = datetime.datetime.now()
sync_plist = plistlib.dumps({
    'revision': int(new_anchor),
    'timestamp': now,
    'operations': [
        {'operation': 'update_db_info', 'pid': random.randint(10**17, 10**18-1),
         'db_info': {'subtitle_language': -1, 'primary_container_pid': 0, 'audio_language': -1}},
        {'operation': 'insert_track', 'pid': asset_id,
         'item': {'title': TITLE, 'sort_name': TITLE.lower(), 'total_time_ms': 125,
                  'date_created': now, 'date_modified': now,
                  'is_movie': True, 'remember_bookmark': True},
         'location': {'kind': 'MPEG-4 video file'},
         'video_info': {'has_alternate_audio': False, 'is_anamorphic': False,
                        'has_subtitles': False, 'is_hd': False, 'is_compressed': False,
                        'has_closed_captions': False, 'is_self_contained': False,
                        'characteristics_valid': False},
         'avformat_info': {'bit_rate': 160, 'audio_format': 502, 'channels': 2},
         'item_stats': {'has_been_played': False, 'play_count_recent': 0,
                        'play_count_user': 0, 'skip_count_user': 0, 'skip_count_recent': 0}},
    ],
}, fmt=plistlib.FMT_BINARY)
cig = compute_cig(device_grappa, sync_plist)
p(f'  Plist: {len(sync_plist)}B, CIG: {len(cig)}B')

# [4] Write files via NATIVE AFC (no pymobiledevice3!)
p(f'\n[4] AFC file operations (native MobileDevice.framework)...')
afc = NativeAFC(found[0])

# Sync plist + CIG
afc.makedirs('/iTunes_Control/Sync/Media')
plist_path = f'/iTunes_Control/Sync/Media/Sync_{int(new_anchor):08d}.plist'
afc.write_file(plist_path, sync_plist)
afc.write_file(plist_path + '.cig', cig)
p(f'  Plist+CIG → {plist_path}')

# Video to Airlock staging
afc.makedirs('/Airlock/Media')
afc.makedirs('/Airlock/Media/Artwork')
airlock_path = f'/Airlock/Media/{asset_id}'
afc.write_file(airlock_path, video_data)
p(f'  Video → {airlock_path} (staging)')

# Video to final path
afc.makedirs(f'/iTunes_Control/Music/{slot}')
afc.write_file(device_path, video_data)
p(f'  Video → {device_path} (final)')

afc.close()

# [5] PowerAssertion + MetadataSyncFinished
p(f'\n[5] PowerAssertion + MetadataSyncFinished (anchor="{new_anchor}")...')
ATH.ATHostConnectionSendPowerAssertion(conn, kCFBooleanTrue)
ATH.ATHostConnectionSendMetadataSyncFinished(conn,
    cfdict(Keybag=cfnum32(1), Media=cfnum32(1)),
    cfdict(Media=cfstr(new_anchor)))

# [6] Read AssetManifest
p('\n[6] Reading AssetManifest...')
got_manifest = False
for i in range(20):
    msg, name = read_msg(conn, 15)
    if name in ['TIMEOUT', None]: p(f'  << {name}'); break
    p(f'  << {name}')
    if name == 'AssetManifest':
        p('  *** GOT ASSET MANIFEST! ***')
        CF.CFShow(msg)
        got_manifest = True
        break
    if name == 'SyncFinished':
        p('  SyncFinished (no manifest)')
        break

if not got_manifest:
    p('No AssetManifest.'); sys.exit(1)

# [7] FileBegin + FileComplete + FileError for stale
p(f'\n[7] File transfer messages...')
str_aid = str(asset_id)
ATH.ATHostConnectionSendMessage(conn, ATH.ATCFMessageCreate(0, cfstr('FileBegin'),
    cfdict(AssetID=cfstr(str_aid), FileSize=cfnum64(file_size),
           TotalSize=cfnum64(file_size), Dataclass=cfstr('Media'))))
p(f'  >> FileBegin')

progress_val = ctypes.c_double(1.0)
cfP = CF.CFNumberCreate(kCFAllocatorDefault, 13, byref(progress_val))
ATH.ATHostConnectionSendMessage(conn, ATH.ATCFMessageCreate(0, cfstr('FileProgress'),
    cfdict(AssetID=cfstr(str_aid), AssetProgress=cfP, OverallProgress=cfP, Dataclass=cfstr('Media'))))
p(f'  >> FileProgress')

ATH.ATHostConnectionSendMessage(conn, ATH.ATCFMessageCreate(0, cfstr('FileComplete'),
    cfdict(AssetID=cfstr(str_aid), AssetPath=cfstr(device_path), Dataclass=cfstr('Media'))))
p(f'  >> FileComplete → {device_path}')

# FileError for any stale pending assets
KNOWN_STALE = ['977648489922361013', '4543310759494544838', '559399545392434047']
for sid in KNOWN_STALE:
    if sid != str_aid:
        ATH.ATHostConnectionSendMessage(conn, ATH.ATCFMessageCreate(0, cfstr('FileError'),
            cfdict(AssetID=cfstr(sid), Dataclass=cfstr('Media'), ErrorCode=cfnum32(0))))
p(f'  >> FileError for stale assets')

# [8] Read SyncFinished
p('\n[8] Reading SyncFinished...')
for i in range(15):
    msg, name = read_msg(conn, 10)
    if name in ['TIMEOUT', None]: p(f'  << {name}'); break
    p(f'  << {name}')
    if name == 'SyncFinished':
        p('  *** SYNC COMPLETE! ***')
        break

ATH.ATHostConnectionInvalidate(conn)
ATH.ATHostConnectionRelease(conn)
p(f'\nDone! "{TITLE}" → {device_path}')
p('Check TV app!')
