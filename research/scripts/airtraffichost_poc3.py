#!/usr/bin/env python3
"""
PoC v3: Quick test — focus on AMDeviceSecureStartService for ATC,
and check what error codes we get. Non-blocking with timeouts.
Also test if ATHostConnection has a callback mode for Grappa.
"""

import ctypes
from ctypes import c_void_p, c_char_p, c_int, c_uint, c_uint64, CFUNCTYPE, POINTER, byref
import signal
import sys

# Timeout handler
def timeout_handler(signum, frame):
    raise TimeoutError("Operation timed out")

signal.signal(signal.SIGALRM, timeout_handler)

CF_PATH = '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation'
MD_PATH = '/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice'
ATH_PATH = '/System/Library/PrivateFrameworks/AirTrafficHost.framework/AirTrafficHost'

CF = ctypes.cdll.LoadLibrary(CF_PATH)
MD = ctypes.cdll.LoadLibrary(MD_PATH)
ATH = ctypes.cdll.LoadLibrary(ATH_PATH)

kCFAllocatorDefault = c_void_p.in_dll(CF, 'kCFAllocatorDefault')
kCFBooleanTrue = c_void_p.in_dll(CF, 'kCFBooleanTrue')
kCFTypeDictionaryKeyCallBacks = c_void_p.in_dll(CF, 'kCFTypeDictionaryKeyCallBacks')
kCFTypeDictionaryValueCallBacks = c_void_p.in_dll(CF, 'kCFTypeDictionaryValueCallBacks')
kCFTypeArrayCallBacks = c_void_p.in_dll(CF, 'kCFTypeArrayCallBacks')
kCFStringEncodingUTF8 = 0x08000100

CF.CFStringCreateWithCString.restype = c_void_p
CF.CFStringCreateWithCString.argtypes = [c_void_p, c_char_p, c_uint]
CF.CFStringGetCString.restype = ctypes.c_bool
CF.CFStringGetCString.argtypes = [c_void_p, c_char_p, c_int, c_uint]
CF.CFArrayGetCount.restype = c_int
CF.CFArrayGetCount.argtypes = [c_void_p]
CF.CFArrayGetValueAtIndex.restype = c_void_p
CF.CFArrayGetValueAtIndex.argtypes = [c_void_p, c_int]
CF.CFShow.restype = None
CF.CFShow.argtypes = [c_void_p]
CF.CFDictionaryCreateMutable.restype = c_void_p
CF.CFDictionaryCreateMutable.argtypes = [c_void_p, c_int, c_void_p, c_void_p]
CF.CFDictionarySetValue.restype = None
CF.CFDictionarySetValue.argtypes = [c_void_p, c_void_p, c_void_p]
CF.CFArrayCreateMutable.restype = c_void_p
CF.CFArrayCreateMutable.argtypes = [c_void_p, c_int, c_void_p]
CF.CFArrayAppendValue.restype = None
CF.CFArrayAppendValue.argtypes = [c_void_p, c_void_p]
CF.CFCopyDescription.restype = c_void_p
CF.CFCopyDescription.argtypes = [c_void_p]
CF.CFRelease.restype = None
CF.CFRelease.argtypes = [c_void_p]

def cfstr(s):
    return CF.CFStringCreateWithCString(kCFAllocatorDefault, s.encode('utf-8'), kCFStringEncodingUTF8)

def cfstr_to_str(cfstring):
    if not cfstring:
        return None
    buf = ctypes.create_string_buffer(4096)
    if CF.CFStringGetCString(cfstring, buf, 4096, kCFStringEncodingUTF8):
        return buf.value.decode('utf-8')
    return None

# MobileDevice
MD.AMDCreateDeviceList.restype = c_void_p
MD.AMDCreateDeviceList.argtypes = []
MD.AMDeviceConnect.restype = c_int
MD.AMDeviceConnect.argtypes = [c_void_p]
MD.AMDeviceIsPaired.restype = c_int
MD.AMDeviceIsPaired.argtypes = [c_void_p]
MD.AMDeviceValidatePairing.restype = c_int
MD.AMDeviceValidatePairing.argtypes = [c_void_p]
MD.AMDeviceStartSession.restype = c_int
MD.AMDeviceStartSession.argtypes = [c_void_p]
MD.AMDeviceCopyDeviceIdentifier.restype = c_void_p
MD.AMDeviceCopyDeviceIdentifier.argtypes = [c_void_p]
MD.AMDeviceCopyValue.restype = c_void_p
MD.AMDeviceCopyValue.argtypes = [c_void_p, c_void_p, c_void_p]
MD.AMDeviceSecureStartService.restype = c_int
MD.AMDeviceSecureStartService.argtypes = [c_void_p, c_void_p, c_void_p, POINTER(c_void_p)]
MD.AMDeviceStartService.restype = c_int
MD.AMDeviceStartService.argtypes = [c_void_p, c_void_p, POINTER(c_void_p), c_void_p]
MD.AMDServiceConnectionGetSocket.restype = c_int
MD.AMDServiceConnectionGetSocket.argtypes = [c_void_p]
MD.AMDServiceConnectionSend.restype = c_int
MD.AMDServiceConnectionSend.argtypes = [c_void_p, c_void_p, c_uint]
MD.AMDServiceConnectionReceive.restype = c_int
MD.AMDServiceConnectionReceive.argtypes = [c_void_p, c_void_p, c_uint]

# AirTrafficHost
ATH.ATHostConnectionCreateWithLibrary.restype = c_void_p
ATH.ATHostConnectionCreateWithLibrary.argtypes = [c_void_p, c_void_p, c_uint]

# Try different flag values
ATH.ATHostConnectionCreate.restype = c_void_p
ATH.ATHostConnectionCreate.argtypes = [c_void_p, c_void_p, c_uint]

ATH.ATHostConnectionCreateWithCallbacks.restype = c_void_p
ATH.ATHostConnectionCreateWithCallbacks.argtypes = [c_void_p, c_void_p, c_void_p]

ATH.ATHostConnectionCreateWithQueryCallback.restype = c_void_p
ATH.ATHostConnectionCreateWithQueryCallback.argtypes = [c_void_p, c_void_p, c_void_p, c_void_p]

ATH.ATHostConnectionGetGrappaSessionId.restype = c_uint
ATH.ATHostConnectionGetGrappaSessionId.argtypes = [c_void_p]
ATH.ATHostConnectionGetCurrentSessionNumber.restype = c_uint
ATH.ATHostConnectionGetCurrentSessionNumber.argtypes = [c_void_p]
ATH.ATHostConnectionSendHostInfo.restype = c_int
ATH.ATHostConnectionSendHostInfo.argtypes = [c_void_p, c_void_p]
ATH.ATHostConnectionReadMessage.restype = c_void_p
ATH.ATHostConnectionReadMessage.argtypes = [c_void_p]
ATH.ATHostConnectionSendSyncRequest.restype = c_int
ATH.ATHostConnectionSendSyncRequest.argtypes = [c_void_p, c_void_p, c_void_p, c_void_p]
ATH.ATHostConnectionSendMessage.restype = c_int
ATH.ATHostConnectionSendMessage.argtypes = [c_void_p, c_void_p]
ATH.ATHostConnectionInvalidate.restype = c_int
ATH.ATHostConnectionInvalidate.argtypes = [c_void_p]
ATH.ATHostConnectionRelease.restype = None
ATH.ATHostConnectionRelease.argtypes = [c_void_p]
ATH.ATHostConnectionSendPowerAssertion.restype = c_int
ATH.ATHostConnectionSendPowerAssertion.argtypes = [c_void_p, c_void_p]

ATH.ATCFMessageGetName.restype = c_void_p
ATH.ATCFMessageGetName.argtypes = [c_void_p]
ATH.ATCFMessageGetParam.restype = c_void_p
ATH.ATCFMessageGetParam.argtypes = [c_void_p, c_void_p]
ATH.ATCFMessageGetSessionNumber.restype = c_uint
ATH.ATCFMessageGetSessionNumber.argtypes = [c_void_p]
ATH.ATCFMessageCreate.restype = c_void_p
ATH.ATCFMessageCreate.argtypes = [c_uint, c_void_p, c_void_p]


def read_msg(conn, timeout_sec=5):
    """Read message with timeout."""
    signal.alarm(timeout_sec)
    try:
        msg = ATH.ATHostConnectionReadMessage(conn)
        signal.alarm(0)
        if not msg:
            return None, None
        name_cf = ATH.ATCFMessageGetName(msg)
        name = cfstr_to_str(name_cf)
        session = ATH.ATCFMessageGetSessionNumber(msg)
        return msg, name
    except TimeoutError:
        signal.alarm(0)
        return None, "TIMEOUT"


def main():
    print("=" * 60)
    print("AirTrafficHost PoC v3 — Service & Connection Tests")
    print("=" * 60)

    # Device
    device_list = MD.AMDCreateDeviceList()
    count = CF.CFArrayGetCount(device_list)
    if count == 0:
        print("[-] No devices")
        return
    device = CF.CFArrayGetValueAtIndex(device_list, 0)
    udid = cfstr_to_str(MD.AMDeviceCopyDeviceIdentifier(device))
    print(f"[+] Device: {udid}")

    err = MD.AMDeviceConnect(device)
    print(f"    Connect: {err}")
    err = MD.AMDeviceValidatePairing(device)
    print(f"    ValidatePairing: {err}")
    err = MD.AMDeviceStartSession(device)
    print(f"    StartSession: {err}")

    name = cfstr_to_str(MD.AMDeviceCopyValue(device, None, cfstr("DeviceName")))
    ios = cfstr_to_str(MD.AMDeviceCopyValue(device, None, cfstr("ProductVersion")))
    print(f"    {name} — iOS {ios}")

    # ── Test 1: AMDeviceSecureStartService for various ATC services ──────────
    print("\n" + "=" * 60)
    print("TEST 1: AMDeviceSecureStartService")
    print("=" * 60)

    services = [
        "com.apple.atc",
        "com.apple.atc2",
        "com.apple.atc.shim.remote",
        "com.apple.atc2.shim.remote",
    ]

    for svc_name in services:
        svc_conn = c_void_p()
        err = MD.AMDeviceSecureStartService(device, cfstr(svc_name), None, byref(svc_conn))
        sock = MD.AMDServiceConnectionGetSocket(svc_conn) if svc_conn.value else -1
        print(f"  {svc_name}: err={err}, conn={hex(svc_conn.value) if svc_conn.value else 'NULL'}, sock={sock}")

    # ── Test 2: AMDeviceStartService (older API) ─────────────────────────────
    print("\n" + "=" * 60)
    print("TEST 2: AMDeviceStartService (legacy)")
    print("=" * 60)

    for svc_name in ["com.apple.atc", "com.apple.atc2"]:
        svc_handle = c_void_p()
        err = MD.AMDeviceStartService(device, cfstr(svc_name), byref(svc_handle), None)
        print(f"  {svc_name}: err={err}, handle={hex(svc_handle.value) if svc_handle.value else 'NULL'}")

    # ── Test 3: ATHostConnection with different flags ─────────────────────────
    print("\n" + "=" * 60)
    print("TEST 3: ATHostConnectionCreateWithLibrary — flag variations")
    print("=" * 60)

    for flags in [0, 1, 2, 4, 8]:
        conn = ATH.ATHostConnectionCreateWithLibrary(cfstr("com.apple.iTunes"), cfstr(udid), flags)
        if conn:
            grappa = ATH.ATHostConnectionGetGrappaSessionId(conn)
            session = ATH.ATHostConnectionGetCurrentSessionNumber(conn)
            print(f"  flags={flags}: conn={hex(conn)}, grappa={grappa}, session={session}")

            # Quick read — what does the device say?
            msg, name = read_msg(conn, timeout_sec=3)
            if name:
                print(f"    First message: {name}")
                # Check for Grappa param
                if name == "Capabilities" or True:
                    gsi = ATH.ATCFMessageGetParam(msg, cfstr("GrappaSupportInfo"))
                    if gsi:
                        print(f"    GrappaSupportInfo present!")
                        CF.CFShow(gsi)

            ATH.ATHostConnectionInvalidate(conn)
            ATH.ATHostConnectionRelease(conn)
        else:
            print(f"  flags={flags}: NULL")

    # ── Test 4: ATHostConnectionCreate (not WithLibrary) ──────────────────────
    print("\n" + "=" * 60)
    print("TEST 4: ATHostConnectionCreate (no library)")
    print("=" * 60)

    conn = ATH.ATHostConnectionCreate(cfstr("com.apple.iTunes"), cfstr(udid), 0)
    if conn:
        grappa = ATH.ATHostConnectionGetGrappaSessionId(conn)
        print(f"  conn={hex(conn)}, grappa={grappa}")

        # Read messages
        for i in range(5):
            msg, name = read_msg(conn, timeout_sec=3)
            if name == "TIMEOUT":
                print(f"  [{i}] Timed out waiting for message")
                break
            if name is None:
                print(f"  [{i}] NULL message")
                break
            print(f"  [{i}] << {name}")

            # After we get some messages, check grappa
            grappa = ATH.ATHostConnectionGetGrappaSessionId(conn)
            if grappa != 0:
                print(f"  *** Grappa session established: {grappa}")

        ATH.ATHostConnectionInvalidate(conn)
        ATH.ATHostConnectionRelease(conn)
    else:
        print("  ATHostConnectionCreate returned NULL")

    # ── Test 5: Try CreateWithCallbacks ───────────────────────────────────────
    print("\n" + "=" * 60)
    print("TEST 5: ATHostConnectionCreateWithCallbacks")
    print("=" * 60)

    # The callback types are unknown, let's try with NULL callbacks
    conn = ATH.ATHostConnectionCreateWithCallbacks(cfstr("com.apple.iTunes"), cfstr(udid), None)
    if conn:
        grappa = ATH.ATHostConnectionGetGrappaSessionId(conn)
        print(f"  conn={hex(conn)}, grappa={grappa}")
        ATH.ATHostConnectionInvalidate(conn)
        ATH.ATHostConnectionRelease(conn)
    else:
        print("  Returned NULL (expected — unknown callback format)")

    print("\n[+] All tests complete")


if __name__ == '__main__':
    main()
