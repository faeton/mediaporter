#!/usr/bin/env python3
"""
AMPDevicesClient with proper block signatures.
PyObjC needs explicit type encoding for callback blocks.
"""
import objc
from Foundation import *
import time
import sys
import os

def p(msg):
    print(msg, flush=True)

# Load framework
bundle = objc.loadBundle(
    'AMPDevices',
    bundle_path='/System/Library/PrivateFrameworks/AMPDevices.framework',
    module_globals=globals()
)
p("[+] AMPDevices.framework loaded")

AMPDevicesClient = objc.lookUpClass('AMPDevicesClient')
AMPDevice = objc.lookUpClass('AMPDevice')

# ── Register block signatures for AMPDevicesClient methods ────────────────
# Block signatures use ObjC type encoding:
#   v = void, @ = id (object), B = BOOL, c = char/bool
#   v@? = void block
#   The block itself is @? in args

# fetchDeviceIdentifiersWithReply: takes a block (NSArray<NSString*>*, NSError*) -> void
objc.registerMetaDataForSelector(
    b'AMPDevicesClient',
    b'fetchDeviceIdentifiersWithReply:',
    {
        'arguments': {
            2: {
                'callable': {
                    'retval': {'type': b'v'},
                    'arguments': {
                        0: {'type': b'^v'},  # block literal
                        1: {'type': b'@'},   # NSArray *
                        2: {'type': b'@'},   # NSError *
                    }
                }
            }
        }
    }
)

# isSyncAllowedForDevice:withReply: block (BOOL, NSError*) -> void
objc.registerMetaDataForSelector(
    b'AMPDevicesClient',
    b'isSyncAllowedForDevice:withReply:',
    {
        'arguments': {
            3: {
                'callable': {
                    'retval': {'type': b'v'},
                    'arguments': {
                        0: {'type': b'^v'},
                        1: {'type': b'Z'},   # BOOL
                        2: {'type': b'@'},   # NSError *
                    }
                }
            }
        }
    }
)

# isSyncInProgressForDevice:withReply:
objc.registerMetaDataForSelector(
    b'AMPDevicesClient',
    b'isSyncInProgressForDevice:withReply:',
    {
        'arguments': {
            3: {
                'callable': {
                    'retval': {'type': b'v'},
                    'arguments': {
                        0: {'type': b'^v'},
                        1: {'type': b'Z'},
                        2: {'type': b'@'},
                    }
                }
            }
        }
    }
)

# canAcceptFiles:forDevice:withReply: block (BOOL, NSError*) -> void
objc.registerMetaDataForSelector(
    b'AMPDevicesClient',
    b'canAcceptFiles:forDevice:withReply:',
    {
        'arguments': {
            4: {
                'callable': {
                    'retval': {'type': b'v'},
                    'arguments': {
                        0: {'type': b'^v'},
                        1: {'type': b'Z'},
                        2: {'type': b'@'},
                    }
                }
            }
        }
    }
)

# copyFiles:toDevice:withReply: block (NSError*) -> void
objc.registerMetaDataForSelector(
    b'AMPDevicesClient',
    b'copyFiles:toDevice:withReply:',
    {
        'arguments': {
            4: {
                'callable': {
                    'retval': {'type': b'v'},
                    'arguments': {
                        0: {'type': b'^v'},
                        1: {'type': b'@'},   # NSError *
                    }
                }
            }
        }
    }
)

# copyObjects:toDevice:withReply: block (NSError*) -> void
objc.registerMetaDataForSelector(
    b'AMPDevicesClient',
    b'copyObjects:toDevice:withReply:',
    {
        'arguments': {
            4: {
                'callable': {
                    'retval': {'type': b'v'},
                    'arguments': {
                        0: {'type': b'^v'},
                        1: {'type': b'@'},
                    }
                }
            }
        }
    }
)

# startSyncForDevice:withOptions:withReply:
objc.registerMetaDataForSelector(
    b'AMPDevicesClient',
    b'startSyncForDevice:withOptions:withReply:',
    {
        'arguments': {
            4: {
                'callable': {
                    'retval': {'type': b'v'},
                    'arguments': {
                        0: {'type': b'^v'},
                        1: {'type': b'@'},
                    }
                }
            }
        },
        'retval': {'type': b'@'}  # returns NSProgress
    }
)

# fetchSettingsForDevice:withReply:
objc.registerMetaDataForSelector(
    b'AMPDevicesClient',
    b'fetchSettingsForDevice:withReply:',
    {
        'arguments': {
            3: {
                'callable': {
                    'retval': {'type': b'v'},
                    'arguments': {
                        0: {'type': b'^v'},
                        1: {'type': b'@'},   # settings dict
                        2: {'type': b'@'},   # NSError *
                    }
                }
            }
        }
    }
)

# fetchBatteryInfoForDevice:withReply:
objc.registerMetaDataForSelector(
    b'AMPDevicesClient',
    b'fetchBatteryInfoForDevice:withReply:',
    {
        'arguments': {
            3: {
                'callable': {
                    'retval': {'type': b'v'},
                    'arguments': {
                        0: {'type': b'^v'},
                        1: {'type': b'@'},
                        2: {'type': b'@'},
                    }
                }
            }
        }
    }
)


def run_loop_wait(flag, timeout=5):
    """Spin the run loop until flag[0] is True or timeout."""
    deadline = time.time() + timeout
    while not flag[0] and time.time() < deadline:
        NSRunLoop.currentRunLoop().runUntilDate_(
            NSDate.dateWithTimeIntervalSinceNow_(0.1)
        )
    return flag[0]


# ── Main flow ─────────────────────────────────────────────────────────────
p("\n=== Creating client ===")
client = AMPDevicesClient.alloc().init()
client.connect()
p("[+] Connected to AMPDevicesAgent")
time.sleep(0.5)

# Step 1: Get device list
p("\n=== Step 1: Fetch device identifiers ===")
devices_done = [False]
device_ids = [None]

def on_devices(ids, error):
    p(f"  Got device IDs: {ids}")
    if error:
        p(f"  Error: {error}")
    device_ids[0] = ids
    devices_done[0] = True

client.fetchDeviceIdentifiersWithReply_(on_devices)
run_loop_wait(devices_done, timeout=5)

if not device_ids[0] or len(device_ids[0]) == 0:
    p("[-] No devices returned from AMPDevicesAgent")
    p("    This may mean XPC was rejected (entitlement check)")
    sys.exit(1)

device_id = device_ids[0][0]
p(f"[+] Device: {device_id}")

# Step 2: Check if sync is allowed
p("\n=== Step 2: Check sync status ===")
sync_done = [False]

def on_sync_allowed(allowed, error):
    p(f"  Sync allowed: {allowed}")
    if error:
        p(f"  Error: {error}")
    sync_done[0] = True

client.isSyncAllowedForDevice_withReply_(device_id, on_sync_allowed)
run_loop_wait(sync_done)

# Step 3: Get battery info (to confirm XPC is working)
p("\n=== Step 3: Battery info ===")
battery_done = [False]

def on_battery(info, error):
    p(f"  Battery: {info}")
    if error:
        p(f"  Error: {error}")
    battery_done[0] = True

client.fetchBatteryInfoForDevice_withReply_(device_id, on_battery)
run_loop_wait(battery_done)

# Step 4: Find test video
p("\n=== Step 4: Find test video ===")
test_file = None
for d in ["/Users/faeton/Sites/mediaporter/test_fixtures",
          "/Users/faeton/Sites/mediaporter"]:
    if os.path.exists(d):
        for f in os.listdir(d):
            if f.endswith(('.m4v', '.mp4', '.mov')):
                candidate = os.path.join(d, f)
                size = os.path.getsize(candidate)
                if size > 1000:  # skip tiny files
                    test_file = candidate
                    p(f"  Found: {test_file} ({size} bytes)")
                    break
    if test_file:
        break

if not test_file:
    p("  No test video found. Looking for any video...")
    import glob
    for pattern in ["*.m4v", "*.mp4", "*.mov"]:
        matches = glob.glob(f"/Users/faeton/Sites/mediaporter/**/{pattern}", recursive=True)
        if matches:
            test_file = matches[0]
            p(f"  Found: {test_file}")
            break

if not test_file:
    p("[-] No test video found")
    sys.exit(1)

# Step 5: canAcceptFiles
p(f"\n=== Step 5: canAcceptFiles ({os.path.basename(test_file)}) ===")
file_url = NSURL.fileURLWithPath_(test_file)
file_array = NSArray.arrayWithObject_(file_url)

accept_done = [False]

def on_accept(can_accept, error):
    p(f"  Can accept: {can_accept}")
    if error:
        p(f"  Error: {error}")
    accept_done[0] = True

client.canAcceptFiles_forDevice_withReply_(file_array, device_id, on_accept)
run_loop_wait(accept_done)

# Step 6: copyFiles!
p(f"\n=== Step 6: copyFiles ===")
copy_done = [False]

def on_copy(error):
    if error:
        p(f"  Copy error: {error}")
    else:
        p(f"  *** COPY SUCCEEDED! ***")
    copy_done[0] = True

client.copyFiles_toDevice_withReply_(file_array, device_id, on_copy)
p("  Waiting for copy (up to 60s)...")
run_loop_wait(copy_done, timeout=60)

if not copy_done[0]:
    p("  Copy timed out")

p("\n[+] Done")
