#!/usr/bin/env python3
"""
Attempt to use AMPDevicesClient.copyFiles:toDevice:withReply: to push a file.
This uses Apple's own daemon to handle Grappa internally.
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

# ── Step 1: Create client and connect ─────────────────────────────────────
p("\n=== Creating AMPDevicesClient ===")

client = AMPDevicesClient.alloc().init()
p(f"  Client: {client}")

# Check connect method
p("  Calling connect...")
try:
    client.connect()
    p("  Connected!")
except Exception as e:
    p(f"  Connect error: {e}")

# Wait a moment for connection
time.sleep(1)

# ── Step 2: Fetch connected devices ───────────────────────────────────────
p("\n=== Fetching devices ===")

# Use callback-based API
result_holder = [None]
error_holder = [None]
done_flag = [False]

def device_ids_reply(identifiers, error):
    p(f"  Callback! identifiers={identifiers}, error={error}")
    result_holder[0] = identifiers
    error_holder[0] = error
    done_flag[0] = True

try:
    client.fetchDeviceIdentifiersWithReply_(device_ids_reply)
    p("  fetchDeviceIdentifiersWithReply_ called, waiting...")

    # Run the run loop to get callbacks
    from AppKit import NSRunLoop, NSDate
    deadline = time.time() + 5
    while not done_flag[0] and time.time() < deadline:
        NSRunLoop.currentRunLoop().runUntilDate_(
            NSDate.dateWithTimeIntervalSinceNow_(0.1)
        )

    if done_flag[0]:
        p(f"  Device identifiers: {result_holder[0]}")
        if error_holder[0]:
            p(f"  Error: {error_holder[0]}")
    else:
        p("  Timed out waiting for device list")
except Exception as e:
    p(f"  Error: {e}")

# ── Step 3: If we got device IDs, get device info ─────────────────────────
if result_holder[0] and len(result_holder[0]) > 0:
    device_id = result_holder[0][0]
    p(f"\n=== Device: {device_id} ===")

    # Fetch device info
    info_holder = [None]
    info_done = [False]

    def info_reply(info, error):
        p(f"  Info callback!")
        info_holder[0] = info
        info_done[0] = True
        if error:
            p(f"  Error: {error}")
        if info:
            p(f"  Info type: {type(info)}")
            p(f"  Info: {info}")

    try:
        # Try different methods to get device info
        for method in ['fetchSettingsForDevice_withReply_',
                       'fetchDeviceInfoForDeviceWithIdentifier_withReply_',
                       'fetchBatteryInfoForDevice_withReply_',
                       'fetchSyncErrorsForDevice_withReply_']:
            if hasattr(client, method):
                p(f"  Trying {method}...")
                info_done[0] = False

                # Create an AMPDevice or pass the identifier string
                try:
                    getattr(client, method)(device_id, info_reply)
                except Exception as e:
                    p(f"    Error calling: {e}")
                    continue

                deadline = time.time() + 3
                while not info_done[0] and time.time() < deadline:
                    NSRunLoop.currentRunLoop().runUntilDate_(
                        NSDate.dateWithTimeIntervalSinceNow_(0.1)
                    )
    except Exception as e:
        p(f"  Error fetching device info: {e}")

    # ── Step 4: Try canAcceptFiles ────────────────────────────────────────
    p("\n=== Testing canAcceptFiles ===")

    # Find a test file
    test_file = None
    test_dir = "/Users/faeton/Sites/mediaporter/test_fixtures"
    if os.path.exists(test_dir):
        for f in os.listdir(test_dir):
            if f.endswith('.m4v') or f.endswith('.mp4'):
                test_file = os.path.join(test_dir, f)
                break

    if not test_file:
        # Create a tiny test file
        test_file = "/tmp/mediaporter_test.mp4"
        if not os.path.exists(test_file):
            p(f"  No test file found. Need a .m4v file.")
        else:
            p(f"  Using: {test_file}")

    if test_file and os.path.exists(test_file):
        file_url = NSURL.fileURLWithPath_(test_file)
        file_array = NSArray.arrayWithObject_(file_url)

        accept_done = [False]
        accept_result = [None]

        def accept_reply(can_accept, error):
            p(f"  canAcceptFiles reply: {can_accept}, error={error}")
            accept_result[0] = can_accept
            accept_done[0] = True

        try:
            client.canAcceptFiles_forDevice_withReply_(file_array, device_id, accept_reply)
            deadline = time.time() + 5
            while not accept_done[0] and time.time() < deadline:
                NSRunLoop.currentRunLoop().runUntilDate_(
                    NSDate.dateWithTimeIntervalSinceNow_(0.1)
                )
        except Exception as e:
            p(f"  Error: {e}")

    # ── Step 5: Try copyFiles ─────────────────────────────────────────────
    if test_file and os.path.exists(test_file):
        p(f"\n=== Attempting copyFiles with {os.path.basename(test_file)} ===")

        copy_done = [False]

        def copy_reply(error):
            p(f"  copyFiles reply! error={error}")
            copy_done[0] = True

        try:
            client.copyFiles_toDevice_withReply_(file_array, device_id, copy_reply)
            p("  copyFiles called, waiting...")

            deadline = time.time() + 30
            while not copy_done[0] and time.time() < deadline:
                NSRunLoop.currentRunLoop().runUntilDate_(
                    NSDate.dateWithTimeIntervalSinceNow_(0.5)
                )

            if not copy_done[0]:
                p("  Timed out waiting for copy")
        except Exception as e:
            p(f"  Error: {e}")
else:
    p("\n[-] No device identifiers returned. XPC may have been rejected.")

    # Try alternative: isSyncAllowedForDevice
    p("\n=== Try isSyncAllowed ===")
    sync_done = [False]

    def sync_reply(allowed, error):
        p(f"  isSyncAllowed: {allowed}, error: {error}")
        sync_done[0] = True

    try:
        if hasattr(client, 'isSyncAllowedForDevice_withReply_'):
            client.isSyncAllowedForDevice_withReply_("00008027-000641441444002E", sync_reply)
            deadline = time.time() + 5
            while not sync_done[0] and time.time() < deadline:
                NSRunLoop.currentRunLoop().runUntilDate_(
                    NSDate.dateWithTimeIntervalSinceNow_(0.1)
                )
    except Exception as e:
        p(f"  Error: {e}")

p("\n[+] Done")
