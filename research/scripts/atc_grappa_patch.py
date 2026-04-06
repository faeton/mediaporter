#!/usr/bin/env python3
"""
ATC sync with PATCHED Grappa session ID.

ATHostConnectionGetGrappaSessionId reads from offset 0x5C in the struct.
We patch that field to non-zero after creating the connection,
then use the high-level SendFileBegin/SendAssetCompleted API.
"""
import asyncio, ctypes, signal, sys, os, random, string
from ctypes import (c_void_p, c_char_p, c_int, c_uint, c_long,
                    c_int64, c_uint32, CFUNCTYPE, POINTER, byref, cast)

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

for fn, rt, at in [
    ('ATHostConnectionCreateWithLibrary', c_void_p, [c_void_p, c_void_p, c_uint]),
    ('ATHostConnectionSendHostInfo', c_void_p, [c_void_p, c_void_p]),
    ('ATHostConnectionReadMessage', c_void_p, [c_void_p]),
    ('ATHostConnectionSendMessage', c_int, [c_void_p, c_void_p]),
    ('ATHostConnectionSendMetadataSyncFinished', c_int, [c_void_p, c_void_p, c_void_p]),
    ('ATHostConnectionSendFileBegin', c_void_p, [c_void_p, c_void_p, c_void_p, c_void_p, c_void_p, c_void_p]),
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
p(f'Device: {found[1][:16]}...')

with open('traces/grappa.bin', 'rb') as f: grappa_bytes = f.read()

# ============================================================
# [1] Create connection
# ============================================================
conn = ATH.ATHostConnectionCreateWithLibrary(cfstr('com.mediaporter.sync'), cfstr(found[1]), 0)
conn_addr = ctypes.cast(conn, ctypes.c_void_p).value
p(f'\n[1] Connection at {hex(conn_addr)}')

# Check Grappa before patch
gid = ATH.ATHostConnectionGetGrappaSessionId(conn)
p(f'  Grappa session ID (before patch): {gid}')

# ============================================================
# [2] PATCH Grappa session ID at offset 0x5C
# ============================================================
GRAPPA_OFFSET = 0x5C  # From disassembly: ldr w0, [x0, #0x5c]
grappa_ptr = ctypes.cast(conn_addr + GRAPPA_OFFSET, ctypes.POINTER(ctypes.c_uint32))
p(f'\n[2] Patching Grappa at {hex(conn_addr + GRAPPA_OFFSET)}')
p(f'  Current value: {grappa_ptr[0]}')
grappa_ptr[0] = 1  # Set to non-zero!
p(f'  Patched to: {grappa_ptr[0]}')

# Verify
gid = ATH.ATHostConnectionGetGrappaSessionId(conn)
p(f'  Grappa session ID (after patch): {gid}')

# ============================================================
# [3] Normal handshake
# ============================================================
p('\n[3] Handshake...')
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

anchor = extract_anchor(msg)
new_anchor = anchor + 1
p(f'  Anchor: {anchor} → {new_anchor}')

# Verify Grappa still patched
gid = ATH.ATHostConnectionGetGrappaSessionId(conn)
p(f'  Grappa session ID (after handshake): {gid}')

# ============================================================
# [4] Upload file via AFC
# ============================================================
asset_id = random.randint(100000000000000000, 999999999999999999)
slot = f'F{random.randint(0,49):02d}'
fname = ''.join(random.choices(string.ascii_uppercase, k=4)) + '.mp4'
device_path = f'/iTunes_Control/Music/{slot}/{fname}'
p(f'\n[4] AFC: {device_path}')

async def afc():
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.afc import AfcService
    ld = await create_using_usbmux()
    async with AfcService(ld) as a:
        try: await a.makedirs(f'/iTunes_Control/Music/{slot}')
        except: pass
        with open(VIDEO, 'rb') as f:
            await a.set_file_contents(device_path, f.read())
        p(f'  Uploaded')
asyncio.run(afc())

# ============================================================
# [5] HIGH-LEVEL SendFileBegin (with patched Grappa!)
# ============================================================
p(f'\n[5] SendFileBegin (HIGH-LEVEL, patched Grappa)...')
cfAssetID = cfnum64(asset_id)
cfSize = cfnum64(file_size)
rc = ATH.ATHostConnectionSendFileBegin(conn, cfAssetID, cfstr('Media'), cfSize, cfSize, cfSize)
p(f'  >> SendFileBegin rc={rc} (ptr={hex(rc) if rc else "NULL"})')

# ============================================================
# [6] HIGH-LEVEL SendAssetCompleted
# ============================================================
p(f'\n[6] SendAssetCompleted (HIGH-LEVEL)...')
rc2 = ATH.ATHostConnectionSendAssetCompleted(conn, cfAssetID, cfstr('Media'), cfstr(device_path))
p(f'  >> SendAssetCompleted rc={rc2} (ptr={hex(rc2) if rc2 else "NULL"})')

# ============================================================
# [7] MetadataSyncFinished
# ============================================================
p(f'\n[7] MetadataSyncFinished (anchor={new_anchor})...')
ATH.ATHostConnectionSendMetadataSyncFinished(conn,
    cfdict(Keybag=cfnum32(1), Media=cfnum32(1)),
    cfdict(Media=cfnum32(new_anchor)))

# ============================================================
# [8] Read responses
# ============================================================
p('\n[8] Reading...')
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
