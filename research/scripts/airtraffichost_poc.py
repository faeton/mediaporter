#!/usr/bin/env python3
"""
Proof-of-concept: Load AirTrafficHost.framework and MobileDevice.framework
via ctypes and attempt to create an ATHostConnection to the connected iPad.

This delegates all Grappa authentication to Apple's own code.
"""

import ctypes
import ctypes.util
from ctypes import c_void_p, c_char_p, c_int, c_uint, c_uint64, CFUNCTYPE, POINTER, byref, cast
import time
import sys

# ── Load frameworks ──────────────────────────────────────────────────────────

MD_PATH = '/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice'
ATH_PATH = '/System/Library/PrivateFrameworks/AirTrafficHost.framework/AirTrafficHost'
CF_PATH = '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation'

print("[*] Loading frameworks...")
CF = ctypes.cdll.LoadLibrary(CF_PATH)
MD = ctypes.cdll.LoadLibrary(MD_PATH)
ATH = ctypes.cdll.LoadLibrary(ATH_PATH)
print("[+] All frameworks loaded successfully")

# ── CoreFoundation helpers ───────────────────────────────────────────────────

CFStringRef = c_void_p
CFDictionaryRef = c_void_p
CFArrayRef = c_void_p
CFBooleanRef = c_void_p
CFNumberRef = c_void_p
CFDataRef = c_void_p
CFAllocatorRef = c_void_p

# kCFAllocatorDefault
kCFAllocatorDefault = c_void_p.in_dll(CF, 'kCFAllocatorDefault')
kCFBooleanTrue = c_void_p.in_dll(CF, 'kCFBooleanTrue')
kCFBooleanFalse = c_void_p.in_dll(CF, 'kCFBooleanFalse')

# CFStringCreateWithCString
CF.CFStringCreateWithCString.restype = CFStringRef
CF.CFStringCreateWithCString.argtypes = [CFAllocatorRef, c_char_p, c_uint]
kCFStringEncodingUTF8 = 0x08000100

def cfstr(s):
    """Create a CFStringRef from a Python string."""
    return CF.CFStringCreateWithCString(kCFAllocatorDefault, s.encode('utf-8'), kCFStringEncodingUTF8)

# CFStringGetCString
CF.CFStringGetCString.restype = ctypes.c_bool
CF.CFStringGetCString.argtypes = [CFStringRef, c_char_p, c_int, c_uint]

def cfstr_to_str(cfstring):
    """Convert a CFStringRef to a Python string."""
    if not cfstring:
        return None
    buf = ctypes.create_string_buffer(1024)
    if CF.CFStringGetCString(cfstring, buf, 1024, kCFStringEncodingUTF8):
        return buf.value.decode('utf-8')
    return None

# CFDictionaryCreateMutable
CF.CFDictionaryCreateMutable.restype = CFDictionaryRef
CF.CFDictionaryCreateMutable.argtypes = [CFAllocatorRef, c_int, c_void_p, c_void_p]

# CFDictionarySetValue
CF.CFDictionarySetValue.restype = None
CF.CFDictionarySetValue.argtypes = [CFDictionaryRef, c_void_p, c_void_p]

# CFArrayCreateMutable / CFArrayAppendValue
CF.CFArrayCreateMutable.restype = CFArrayRef
CF.CFArrayCreateMutable.argtypes = [CFAllocatorRef, c_int, c_void_p]

CF.CFArrayAppendValue.restype = None
CF.CFArrayAppendValue.argtypes = [CFArrayRef, c_void_p]

# CFRelease
CF.CFRelease.restype = None
CF.CFRelease.argtypes = [c_void_p]

# CFShow (for debugging)
CF.CFShow.restype = None
CF.CFShow.argtypes = [c_void_p]

# kCFTypeDictionaryKeyCallBacks / kCFTypeDictionaryValueCallBacks
kCFTypeDictionaryKeyCallBacks = c_void_p.in_dll(CF, 'kCFTypeDictionaryKeyCallBacks')
kCFTypeDictionaryValueCallBacks = c_void_p.in_dll(CF, 'kCFTypeDictionaryValueCallBacks')
kCFTypeArrayCallBacks = c_void_p.in_dll(CF, 'kCFTypeArrayCallBacks')


# ── MobileDevice functions ───────────────────────────────────────────────────

# Device notification callback type
# typedef void (*am_device_notification_callback)(struct am_device_notification_callback_info *, void *)
AMDeviceNotificationCallback = CFUNCTYPE(None, c_void_p, c_void_p)

MD.AMDeviceNotificationSubscribe.restype = c_int
MD.AMDeviceNotificationSubscribe.argtypes = [AMDeviceNotificationCallback, c_uint, c_uint, c_void_p, POINTER(c_void_p)]

MD.AMDeviceConnect.restype = c_int
MD.AMDeviceConnect.argtypes = [c_void_p]

MD.AMDeviceIsPaired.restype = c_int
MD.AMDeviceIsPaired.argtypes = [c_void_p]

MD.AMDeviceValidatePairing.restype = c_int
MD.AMDeviceValidatePairing.argtypes = [c_void_p]

MD.AMDeviceStartSession.restype = c_int
MD.AMDeviceStartSession.argtypes = [c_void_p]

MD.AMDeviceStartService.restype = c_int
MD.AMDeviceStartService.argtypes = [c_void_p, CFStringRef, POINTER(c_void_p), c_void_p]

MD.AMDeviceSecureStartService.restype = c_int
MD.AMDeviceSecureStartService.argtypes = [c_void_p, CFStringRef, c_void_p, POINTER(c_void_p)]

MD.AMDeviceCopyDeviceIdentifier.restype = CFStringRef
MD.AMDeviceCopyDeviceIdentifier.argtypes = [c_void_p]

MD.AMDeviceCopyValue.restype = c_void_p
MD.AMDeviceCopyValue.argtypes = [c_void_p, CFStringRef, CFStringRef]

MD.AMDCreateDeviceList.restype = CFArrayRef
MD.AMDCreateDeviceList.argtypes = []

# CFArray helpers
CF.CFArrayGetCount.restype = c_int
CF.CFArrayGetCount.argtypes = [CFArrayRef]

CF.CFArrayGetValueAtIndex.restype = c_void_p
CF.CFArrayGetValueAtIndex.argtypes = [CFArrayRef, c_int]

# ── AirTrafficHost functions ─────────────────────────────────────────────────

ATH.ATHostConnectionCreateWithLibrary.restype = c_void_p
ATH.ATHostConnectionCreateWithLibrary.argtypes = [CFStringRef, CFStringRef, c_uint]

ATH.ATHostConnectionCreate.restype = c_void_p
ATH.ATHostConnectionCreate.argtypes = [CFStringRef, CFStringRef, c_uint]

ATH.ATHostConnectionDestroy.restype = None
ATH.ATHostConnectionDestroy.argtypes = [c_void_p]

ATH.ATHostConnectionGetGrappaSessionId.restype = c_uint
ATH.ATHostConnectionGetGrappaSessionId.argtypes = [c_void_p]

ATH.ATHostConnectionGetCurrentSessionNumber.restype = c_uint
ATH.ATHostConnectionGetCurrentSessionNumber.argtypes = [c_void_p]

ATH.ATHostConnectionSendHostInfo.restype = c_int
ATH.ATHostConnectionSendHostInfo.argtypes = [c_void_p, CFDictionaryRef]

ATH.ATHostConnectionSendPowerAssertion.restype = c_int
ATH.ATHostConnectionSendPowerAssertion.argtypes = [c_void_p, CFBooleanRef]

ATH.ATHostConnectionSendSyncRequest.restype = c_int
ATH.ATHostConnectionSendSyncRequest.argtypes = [c_void_p, CFArrayRef, CFDictionaryRef, CFDictionaryRef]

ATH.ATHostConnectionReadMessage.restype = c_void_p  # returns ATCFMessage
ATH.ATHostConnectionReadMessage.argtypes = [c_void_p]

ATH.ATHostConnectionSendMetadataSyncFinished.restype = c_int
ATH.ATHostConnectionSendMetadataSyncFinished.argtypes = [c_void_p, CFDictionaryRef, CFDictionaryRef]

ATH.ATHostConnectionSendFileBegin.restype = c_int
ATH.ATHostConnectionSendFileBegin.argtypes = [c_void_p, CFDictionaryRef]  # guessing dict

ATH.ATHostConnectionSendFileProgress.restype = c_int
ATH.ATHostConnectionSendFileProgress.argtypes = [c_void_p, CFDictionaryRef]  # guessing

ATH.ATHostConnectionSendAssetCompleted.restype = c_int
ATH.ATHostConnectionSendAssetCompleted.argtypes = [c_void_p, CFStringRef, CFStringRef, CFDictionaryRef]  # guessing

ATH.ATHostConnectionSendMessage.restype = c_int
ATH.ATHostConnectionSendMessage.argtypes = [c_void_p, c_void_p]  # send raw ATCFMessage

ATH.ATHostConnectionInvalidate.restype = c_int
ATH.ATHostConnectionInvalidate.argtypes = [c_void_p]

ATH.ATHostConnectionRelease.restype = None
ATH.ATHostConnectionRelease.argtypes = [c_void_p]

ATH.ATHostConnectionRetain.restype = c_void_p
ATH.ATHostConnectionRetain.argtypes = [c_void_p]

# ATCFMessage functions
ATH.ATCFMessageCreate.restype = c_void_p
ATH.ATCFMessageCreate.argtypes = [c_uint, CFStringRef, CFDictionaryRef]  # session, command, params

ATH.ATCFMessageGetName.restype = CFStringRef
ATH.ATCFMessageGetName.argtypes = [c_void_p]

ATH.ATCFMessageGetParam.restype = c_void_p
ATH.ATCFMessageGetParam.argtypes = [c_void_p, CFStringRef]

ATH.ATCFMessageGetSessionNumber.restype = c_uint
ATH.ATCFMessageGetSessionNumber.argtypes = [c_void_p]

# ── Main PoC ─────────────────────────────────────────────────────────────────

def main():
    print("\n[*] Step 1: List connected devices via MobileDevice.framework")

    # Method 1: Try AMDCreateDeviceList
    device_list = MD.AMDCreateDeviceList()
    if device_list:
        count = CF.CFArrayGetCount(device_list)
        print(f"[+] Found {count} device(s) via AMDCreateDeviceList")

        if count == 0:
            print("[-] No devices found. Is iPad connected and trusted?")
            return

        device = CF.CFArrayGetValueAtIndex(device_list, 0)
        print(f"[+] Device handle: {hex(device)}")
    else:
        print("[-] AMDCreateDeviceList returned NULL")
        print("[*] Trying notification-based discovery...")

        # Method 2: Use notification subscription (async, need to wait)
        found_device = [None]

        @AMDeviceNotificationCallback
        def device_callback(info_ptr, user_data):
            # info struct: { device, msg_type }
            # msg_type: 1=connected, 2=disconnected
            device = cast(info_ptr, POINTER(c_void_p))[0]
            msg_type = cast(info_ptr, POINTER(c_void_p))[1]
            if msg_type and int(msg_type) == 1:  # connected
                found_device[0] = device
                print(f"[+] Device connected: {hex(device)}")

        notification = c_void_p()
        err = MD.AMDeviceNotificationSubscribe(device_callback, 0, 0, None, byref(notification))
        print(f"[*] AMDeviceNotificationSubscribe returned: {err}")

        # Run the run loop briefly to get callbacks
        CF.CFRunLoopRunInMode.restype = c_int
        CF.CFRunLoopRunInMode.argtypes = [CFStringRef, ctypes.c_double, ctypes.c_bool]
        kCFRunLoopDefaultMode = c_void_p.in_dll(CF, 'kCFRunLoopDefaultMode')

        print("[*] Waiting for device notification (5 seconds)...")
        CF.CFRunLoopRunInMode(kCFRunLoopDefaultMode, 5.0, False)

        device = found_device[0]
        if not device:
            print("[-] No device found via notifications either.")
            return

    # Get device UDID
    udid_cf = MD.AMDeviceCopyDeviceIdentifier(device)
    udid = cfstr_to_str(udid_cf)
    print(f"[+] Device UDID: {udid}")

    # Connect to device
    print("\n[*] Step 2: Connect to device")
    err = MD.AMDeviceConnect(device)
    print(f"    AMDeviceConnect: {err}")

    if err != 0:
        print(f"[-] AMDeviceConnect failed with error {err}")
        print("[!] This may mean the tunnel isn't running or the device isn't properly connected")
        # Try continuing anyway — device might already be connected

    paired = MD.AMDeviceIsPaired(device)
    print(f"    AMDeviceIsPaired: {paired}")

    err = MD.AMDeviceValidatePairing(device)
    print(f"    AMDeviceValidatePairing: {err}")

    err = MD.AMDeviceStartSession(device)
    print(f"    AMDeviceStartSession: {err}")

    # Get device name
    name_cf = MD.AMDeviceCopyValue(device, None, cfstr("DeviceName"))
    name = cfstr_to_str(name_cf) if name_cf else "Unknown"
    print(f"    Device name: {name}")

    model_cf = MD.AMDeviceCopyValue(device, None, cfstr("ProductType"))
    model = cfstr_to_str(model_cf) if model_cf else "Unknown"
    print(f"    Product type: {model}")

    ios_cf = MD.AMDeviceCopyValue(device, None, cfstr("ProductVersion"))
    ios = cfstr_to_str(ios_cf) if ios_cf else "Unknown"
    print(f"    iOS version: {ios}")

    # ── Step 3: Create AirTrafficHost connection ─────────────────────────────
    print("\n[*] Step 3: Create ATHostConnection")

    library_id = cfstr("com.mediaporter.library")
    device_udid = cfstr(udid or "00008027-000641441444002E")

    # Try ATHostConnectionCreateWithLibrary
    conn = ATH.ATHostConnectionCreateWithLibrary(library_id, device_udid, 0)
    print(f"    ATHostConnectionCreateWithLibrary: {hex(conn) if conn else 'NULL'}")

    if not conn:
        print("[*] Trying ATHostConnectionCreate...")
        conn = ATH.ATHostConnectionCreate(library_id, device_udid, 0)
        print(f"    ATHostConnectionCreate: {hex(conn) if conn else 'NULL'}")

    if not conn:
        print("[-] Failed to create ATHostConnection")
        return

    grappa_id = ATH.ATHostConnectionGetGrappaSessionId(conn)
    session_num = ATH.ATHostConnectionGetCurrentSessionNumber(conn)
    print(f"    Grappa session ID: {grappa_id}")
    print(f"    Current session number: {session_num}")

    # ── Step 4: Send HostInfo ─────────────────────────────────────────────────
    print("\n[*] Step 4: Send HostInfo")

    host_info = CF.CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0,
        kCFTypeDictionaryKeyCallBacks,
        kCFTypeDictionaryValueCallBacks
    )
    CF.CFDictionarySetValue(host_info, cfstr("HostName"), cfstr("mediaporter"))
    CF.CFDictionarySetValue(host_info, cfstr("HostID"), cfstr("com.mediaporter.host"))
    CF.CFDictionarySetValue(host_info, cfstr("Version"), cfstr("10.5.0.115"))

    err = ATH.ATHostConnectionSendHostInfo(conn, host_info)
    print(f"    ATHostConnectionSendHostInfo: {err}")

    # ── Step 5: Send power assertion ──────────────────────────────────────────
    print("\n[*] Step 5: Send power assertion")
    err = ATH.ATHostConnectionSendPowerAssertion(conn, kCFBooleanTrue)
    print(f"    ATHostConnectionSendPowerAssertion: {err}")

    # ── Step 6: Read messages from device ─────────────────────────────────────
    print("\n[*] Step 6: Read device messages")

    for i in range(5):
        print(f"\n    --- Reading message {i+1} ---")
        msg = ATH.ATHostConnectionReadMessage(conn)
        if not msg:
            print("    [!] ReadMessage returned NULL")
            break

        name_cf = ATH.ATCFMessageGetName(msg)
        name = cfstr_to_str(name_cf)
        session = ATH.ATCFMessageGetSessionNumber(msg)
        print(f"    Message: {name} (session: {session})")

        # Try to get some params
        for param_name in ["GrappaSupportInfo", "ErrorCode", "ManualSync", "_FreeSize"]:
            param = ATH.ATCFMessageGetParam(msg, cfstr(param_name))
            if param:
                print(f"    Param '{param_name}': {hex(param)}")
                CF.CFShow(param)

    # ── Step 7: Send sync request ─────────────────────────────────────────────
    print("\n[*] Step 7: Send sync request")

    data_classes = CF.CFArrayCreateMutable(kCFAllocatorDefault, 0, kCFTypeArrayCallBacks)
    CF.CFArrayAppendValue(data_classes, cfstr("com.apple.media"))

    anchors = CF.CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0,
        kCFTypeDictionaryKeyCallBacks,
        kCFTypeDictionaryValueCallBacks
    )

    err = ATH.ATHostConnectionSendSyncRequest(conn, data_classes, anchors, None)
    print(f"    ATHostConnectionSendSyncRequest: {err}")

    # Read response
    for i in range(3):
        print(f"\n    --- Reading response {i+1} ---")
        msg = ATH.ATHostConnectionReadMessage(conn)
        if not msg:
            print("    [!] ReadMessage returned NULL")
            break

        name_cf = ATH.ATCFMessageGetName(msg)
        name = cfstr_to_str(name_cf)
        session = ATH.ATCFMessageGetSessionNumber(msg)
        print(f"    Message: {name} (session: {session})")

        # Check for errors
        error_param = ATH.ATCFMessageGetParam(msg, cfstr("ErrorCode"))
        if error_param:
            print(f"    ErrorCode present!")
            CF.CFShow(error_param)

        if name == "SyncFailed":
            reason = ATH.ATCFMessageGetParam(msg, cfstr("Reason"))
            if reason:
                print("    Reason:")
                CF.CFShow(reason)
            break

    # Check Grappa session after handshake attempt
    grappa_id = ATH.ATHostConnectionGetGrappaSessionId(conn)
    print(f"\n[*] Grappa session ID after handshake: {grappa_id}")

    # Cleanup
    print("\n[*] Cleaning up...")
    ATH.ATHostConnectionInvalidate(conn)
    ATH.ATHostConnectionRelease(conn)
    print("[+] Done!")


if __name__ == '__main__':
    main()
