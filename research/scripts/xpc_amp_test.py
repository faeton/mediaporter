#!/usr/bin/env python3
"""
Test: Use AMPDevicesClient and AMPDevice to interact with AMPDevicesAgent.
Explore the actual API surface available to us.
"""
import objc
from Foundation import *
import time
import sys

def p(msg):
    print(msg, flush=True)

# Load AMPDevices framework
bundle = objc.loadBundle(
    'AMPDevices',
    bundle_path='/System/Library/PrivateFrameworks/AMPDevices.framework',
    module_globals=globals()
)
p("[+] AMPDevices.framework loaded")

# ── Explore AMPDevicesClient ──────────────────────────────────────────────
p("\n=== AMPDevicesClient ===")
try:
    cls = objc.lookUpClass('AMPDevicesClient')
    p(f"  Class: {cls}")

    # List all methods
    methods = [m for m in dir(cls) if not m.startswith('__')]
    p(f"  Methods ({len(methods)}):")
    for m in sorted(methods):
        if any(k in m.lower() for k in ['device', 'sync', 'copy', 'file', 'connect', 'start',
                                          'accept', 'delete', 'media', 'content', 'transfer',
                                          'init', 'shared', 'default', 'create']):
            p(f"    {m}")
except Exception as e:
    p(f"  Error: {e}")

# ── Explore AMPDevice ─────────────────────────────────────────────────────
p("\n=== AMPDevice ===")
try:
    cls = objc.lookUpClass('AMPDevice')
    methods = [m for m in dir(cls) if not m.startswith('__')]
    p(f"  Methods ({len(methods)}):")
    for m in sorted(methods):
        if any(k in m.lower() for k in ['device', 'sync', 'copy', 'file', 'connect', 'start',
                                          'identifier', 'name', 'udid', 'serial', 'init',
                                          'content', 'transfer', 'media']):
            p(f"    {m}")
except Exception as e:
    p(f"  Error: {e}")

# ── Explore AMPDiscoveryClient ────────────────────────────────────────────
p("\n=== AMPDiscoveryClient ===")
try:
    cls = objc.lookUpClass('AMPDiscoveryClient')
    methods = [m for m in dir(cls) if not m.startswith('__')]
    p(f"  Methods ({len(methods)}):")
    for m in sorted(methods):
        if any(k in m.lower() for k in ['device', 'discover', 'connect', 'start', 'stop',
                                          'init', 'shared', 'default', 'create', 'list',
                                          'delegate', 'handler']):
            p(f"    {m}")
except Exception as e:
    p(f"  Error: {e}")

# ── Explore AMPDeviceViewConnection ───────────────────────────────────────
p("\n=== AMPDeviceViewConnection ===")
try:
    cls = objc.lookUpClass('AMPDeviceViewConnection')
    methods = [m for m in dir(cls) if not m.startswith('__')]
    p(f"  Methods ({len(methods)}):")
    for m in sorted(methods):
        if any(k in m.lower() for k in ['device', 'sync', 'copy', 'file', 'connect', 'start',
                                          'init', 'shared', 'default', 'create', 'content',
                                          'media', 'transfer', 'accept', 'delete']):
            p(f"    {m}")
except Exception as e:
    p(f"  Error: {e}")

# ── Try to instantiate AMPDevicesClient ───────────────────────────────────
p("\n=== Try instantiating AMPDevicesClient ===")
try:
    client = objc.lookUpClass('AMPDevicesClient').alloc().init()
    p(f"  Instance: {client}")

    # Try common methods
    for method_name in ['devices', 'connectedDevices', 'deviceList', 'allDevices']:
        if hasattr(client, method_name):
            try:
                result = getattr(client, method_name)()
                p(f"  .{method_name}(): {result}")
            except Exception as e:
                p(f"  .{method_name}(): Error: {e}")
except Exception as e:
    p(f"  Error creating client: {e}")

# ── Try to instantiate AMPDiscoveryClient ─────────────────────────────────
p("\n=== Try instantiating AMPDiscoveryClient ===")
try:
    disc = objc.lookUpClass('AMPDiscoveryClient').alloc().init()
    p(f"  Instance: {disc}")

    for method_name in ['devices', 'connectedDevices', 'startDiscovery', 'discoveredDevices']:
        if hasattr(disc, method_name):
            try:
                result = getattr(disc, method_name)()
                p(f"  .{method_name}(): {result}")
            except Exception as e:
                p(f"  .{method_name}(): Error: {e}")
except Exception as e:
    p(f"  Error creating discovery client: {e}")

# ── Full method dump for key classes ──────────────────────────────────────
p("\n=== Full method dump: AMPDevicesClient ===")
try:
    cls = objc.lookUpClass('AMPDevicesClient')
    for m in sorted(dir(cls)):
        if not m.startswith('_') or m.startswith('init'):
            p(f"  {m}")
except: pass

p("\n=== Full method dump: AMPDeviceViewConnection ===")
try:
    cls = objc.lookUpClass('AMPDeviceViewConnection')
    for m in sorted(dir(cls)):
        if not m.startswith('_') or m.startswith('init'):
            p(f"  {m}")
except: pass

p("\n[+] Done")
