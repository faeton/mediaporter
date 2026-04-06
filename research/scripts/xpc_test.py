#!/usr/bin/env python3
"""
Test: Connect to AMPDevicesAgent XPC and attempt to call copyFiles:toDevice:withReply:
"""
import objc
from Foundation import (
    NSXPCConnection, NSObject, NSXPCInterface, NSArray, NSURL,
    NSError, NSString, NSMutableDictionary
)
import time
import sys

def p(msg):
    print(msg, flush=True)

# ── Define the AMPDevicesProtocol interface ──────────────────────────────────

# First, let's try to connect and see what happens
p("=== Test 1: Connect to AMPDevicesAgent XPC ===")

try:
    # Try different service names
    for svc_name in [
        'com.apple.AMPDevicesAgent',
        'com.apple.amp.devices',
        'com.apple.amp.devices.client',
    ]:
        p(f"\n  Trying: {svc_name}")
        try:
            conn = NSXPCConnection.alloc().initWithMachServiceName_options_(
                svc_name, 0  # 0 = no privileged helper
            )
            p(f"    Connection object: {conn}")

            # Set up error handler
            class ErrorHandler(NSObject):
                @objc.python_method
                def handleError_(self, error):
                    p(f"    XPC Error: {error}")

            handler = ErrorHandler.alloc().init()
            conn.setInterruptionHandler_(lambda: p(f"    [{svc_name}] Interrupted!"))
            conn.setInvalidationHandler_(lambda: p(f"    [{svc_name}] Invalidated!"))

            conn.resume()
            p(f"    Resumed successfully")

            # Try to get remote object proxy
            proxy = conn.remoteObjectProxy()
            p(f"    Proxy: {proxy}")

            # Try calling a simple method
            try:
                # Use synchronous proxy with error handler
                proxy_with_error = conn.remoteObjectProxyWithErrorHandler_(
                    lambda err: p(f"    Proxy error: {err}")
                )
                p(f"    Proxy with error handler: {proxy_with_error}")
            except Exception as e:
                p(f"    Error getting proxy: {e}")

            # Don't invalidate yet — check if we can call methods
            time.sleep(1)
            conn.invalidate()

        except Exception as e:
            p(f"    Error: {e}")

except Exception as e:
    p(f"  Fatal: {e}")

# ── Test 2: Try loading AMPDevices.framework ──────────────────────────────
p("\n=== Test 2: Load AMPDevices.framework ===")

try:
    bundle_path = '/System/Library/PrivateFrameworks/AMPDevices.framework'
    bundle = objc.loadBundle(
        'AMPDevices',
        bundle_path=bundle_path,
        module_globals=globals()
    )
    p(f"  Loaded: {bundle}")

    # List all classes from the bundle
    import Foundation
    all_classes = objc.getClassList()
    amp_classes = [c for c in all_classes if 'AMP' in c.__name__ or 'ATHost' in c.__name__]
    p(f"  AMP/ATHost classes found: {len(amp_classes)}")
    for cls in sorted(amp_classes, key=lambda c: c.__name__)[:30]:
        p(f"    {cls.__name__}")

except Exception as e:
    p(f"  Error loading framework: {e}")

# ── Test 3: Try loading AirTrafficHost.framework ObjC classes ─────────────
p("\n=== Test 3: Load AirTrafficHost.framework classes ===")

try:
    bundle = objc.loadBundle(
        'AirTrafficHost',
        bundle_path='/System/Library/PrivateFrameworks/AirTrafficHost.framework',
        module_globals=globals()
    )
    p(f"  Loaded: {bundle}")

    all_classes = objc.getClassList()
    at_classes = [c for c in all_classes if c.__name__.startswith('AT')]
    p(f"  AT* classes: {len(at_classes)}")
    for cls in sorted(at_classes, key=lambda c: c.__name__)[:20]:
        p(f"    {cls.__name__}")

except Exception as e:
    p(f"  Error: {e}")

p("\n[+] Done")
