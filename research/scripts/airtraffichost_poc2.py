#!/usr/bin/env python3
"""
PoC v2: Correct message ordering — read device greeting first,
let the framework handle Grappa, then send our requests.

Also try ATHostConnectionSendMessage with raw ATCFMessages.
"""

import ctypes
from ctypes import c_void_p, c_char_p, c_int, c_uint, c_uint64, c_int32, CFUNCTYPE, POINTER, byref, cast
import struct
import sys

# ── Load frameworks ──────────────────────────────────────────────────────────

CF_PATH = '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation'
MD_PATH = '/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice'
ATH_PATH = '/System/Library/PrivateFrameworks/AirTrafficHost.framework/AirTrafficHost'

CF = ctypes.cdll.LoadLibrary(CF_PATH)
MD = ctypes.cdll.LoadLibrary(MD_PATH)
ATH = ctypes.cdll.LoadLibrary(ATH_PATH)
print("[+] Frameworks loaded")

# ── CoreFoundation helpers ───────────────────────────────────────────────────

kCFAllocatorDefault = c_void_p.in_dll(CF, 'kCFAllocatorDefault')
kCFBooleanTrue = c_void_p.in_dll(CF, 'kCFBooleanTrue')
kCFBooleanFalse = c_void_p.in_dll(CF, 'kCFBooleanFalse')
kCFTypeDictionaryKeyCallBacks = c_void_p.in_dll(CF, 'kCFTypeDictionaryKeyCallBacks')
kCFTypeDictionaryValueCallBacks = c_void_p.in_dll(CF, 'kCFTypeDictionaryValueCallBacks')
kCFTypeArrayCallBacks = c_void_p.in_dll(CF, 'kCFTypeArrayCallBacks')
kCFStringEncodingUTF8 = 0x08000100

CF.CFStringCreateWithCString.restype = c_void_p
CF.CFStringCreateWithCString.argtypes = [c_void_p, c_char_p, c_uint]

CF.CFStringGetCString.restype = ctypes.c_bool
CF.CFStringGetCString.argtypes = [c_void_p, c_char_p, c_int, c_uint]

CF.CFDictionaryCreateMutable.restype = c_void_p
CF.CFDictionaryCreateMutable.argtypes = [c_void_p, c_int, c_void_p, c_void_p]

CF.CFDictionarySetValue.restype = None
CF.CFDictionarySetValue.argtypes = [c_void_p, c_void_p, c_void_p]

CF.CFArrayCreateMutable.restype = c_void_p
CF.CFArrayCreateMutable.argtypes = [c_void_p, c_int, c_void_p]

CF.CFArrayAppendValue.restype = None
CF.CFArrayAppendValue.argtypes = [c_void_p, c_void_p]

CF.CFArrayGetCount.restype = c_int
CF.CFArrayGetCount.argtypes = [c_void_p]

CF.CFArrayGetValueAtIndex.restype = c_void_p
CF.CFArrayGetValueAtIndex.argtypes = [c_void_p, c_int]

CF.CFShow.restype = None
CF.CFShow.argtypes = [c_void_p]

CF.CFRelease.restype = None
CF.CFRelease.argtypes = [c_void_p]

CF.CFNumberCreate.restype = c_void_p
CF.CFNumberCreate.argtypes = [c_void_p, c_int, c_void_p]
kCFNumberSInt32Type = 3
kCFNumberSInt64Type = 4

CF.CFGetTypeID.restype = c_uint
CF.CFGetTypeID.argtypes = [c_void_p]

CF.CFDictionaryGetTypeID.restype = c_uint
CF.CFStringGetTypeID.restype = c_uint
CF.CFNumberGetTypeID.restype = c_uint
CF.CFBooleanGetTypeID.restype = c_uint
CF.CFArrayGetTypeID.restype = c_uint
CF.CFDataGetTypeID.restype = c_uint

CF.CFDictionaryGetCount.restype = c_int
CF.CFDictionaryGetCount.argtypes = [c_void_p]

CF.CFCopyDescription.restype = c_void_p
CF.CFCopyDescription.argtypes = [c_void_p]

def cfstr(s):
    return CF.CFStringCreateWithCString(kCFAllocatorDefault, s.encode('utf-8'), kCFStringEncodingUTF8)

def cfstr_to_str(cfstring):
    if not cfstring:
        return None
    buf = ctypes.create_string_buffer(4096)
    if CF.CFStringGetCString(cfstring, buf, 4096, kCFStringEncodingUTF8):
        return buf.value.decode('utf-8')
    return None

def cfnum(val):
    v = c_int32(val)
    return CF.CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, byref(v))

def cf_describe(obj):
    """Get a string description of any CF object."""
    if not obj:
        return "NULL"
    desc = CF.CFCopyDescription(obj)
    s = cfstr_to_str(desc) if desc else "?"
    if desc:
        CF.CFRelease(desc)
    return s

# ── MobileDevice ─────────────────────────────────────────────────────────────

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

# ── AirTrafficHost ───────────────────────────────────────────────────────────

ATH.ATHostConnectionCreateWithLibrary.restype = c_void_p
ATH.ATHostConnectionCreateWithLibrary.argtypes = [c_void_p, c_void_p, c_uint]

ATH.ATHostConnectionCreate.restype = c_void_p
ATH.ATHostConnectionCreate.argtypes = [c_void_p, c_void_p, c_uint]

ATH.ATHostConnectionDestroy.restype = None
ATH.ATHostConnectionDestroy.argtypes = [c_void_p]

ATH.ATHostConnectionGetGrappaSessionId.restype = c_uint
ATH.ATHostConnectionGetGrappaSessionId.argtypes = [c_void_p]

ATH.ATHostConnectionGetCurrentSessionNumber.restype = c_uint
ATH.ATHostConnectionGetCurrentSessionNumber.argtypes = [c_void_p]

ATH.ATHostConnectionSendHostInfo.restype = c_int
ATH.ATHostConnectionSendHostInfo.argtypes = [c_void_p, c_void_p]

ATH.ATHostConnectionSendPowerAssertion.restype = c_int
ATH.ATHostConnectionSendPowerAssertion.argtypes = [c_void_p, c_void_p]

ATH.ATHostConnectionSendSyncRequest.restype = c_int
ATH.ATHostConnectionSendSyncRequest.argtypes = [c_void_p, c_void_p, c_void_p, c_void_p]

ATH.ATHostConnectionReadMessage.restype = c_void_p
ATH.ATHostConnectionReadMessage.argtypes = [c_void_p]

ATH.ATHostConnectionSendMetadataSyncFinished.restype = c_int
ATH.ATHostConnectionSendMetadataSyncFinished.argtypes = [c_void_p, c_void_p, c_void_p]

ATH.ATHostConnectionSendMessage.restype = c_int
ATH.ATHostConnectionSendMessage.argtypes = [c_void_p, c_void_p]

ATH.ATHostConnectionInvalidate.restype = c_int
ATH.ATHostConnectionInvalidate.argtypes = [c_void_p]

ATH.ATHostConnectionRelease.restype = None
ATH.ATHostConnectionRelease.argtypes = [c_void_p]

ATH.ATHostConnectionSendFileBegin.restype = c_int
ATH.ATHostConnectionSendFileBegin.argtypes = [c_void_p, c_void_p]

ATH.ATHostConnectionSendFileProgress.restype = c_int
ATH.ATHostConnectionSendFileProgress.argtypes = [c_void_p, c_void_p]

ATH.ATHostConnectionSendAssetCompleted.restype = c_int
ATH.ATHostConnectionSendAssetCompleted.argtypes = [c_void_p, c_void_p, c_void_p, c_void_p]

ATH.ATHostConnectionSendAssetMetricsRequest.restype = c_int
ATH.ATHostConnectionSendAssetMetricsRequest.argtypes = [c_void_p]

ATH.ATHostConnectionSendPing.restype = c_int
ATH.ATHostConnectionSendPing.argtypes = [c_void_p]

ATH.ATHostConnectionSendConnectionInvalid.restype = c_int
ATH.ATHostConnectionSendConnectionInvalid.argtypes = [c_void_p]

# ATCFMessage
ATH.ATCFMessageCreate.restype = c_void_p
ATH.ATCFMessageCreate.argtypes = [c_uint, c_void_p, c_void_p]

ATH.ATCFMessageGetName.restype = c_void_p
ATH.ATCFMessageGetName.argtypes = [c_void_p]

ATH.ATCFMessageGetParam.restype = c_void_p
ATH.ATCFMessageGetParam.argtypes = [c_void_p, c_void_p]

ATH.ATCFMessageGetSessionNumber.restype = c_uint
ATH.ATCFMessageGetSessionNumber.argtypes = [c_void_p]

# ATHostCreateDeviceServiceConnection - might need this
ATH.ATHostCreateDeviceServiceConnection.restype = c_void_p
ATH.ATHostCreateDeviceServiceConnection.argtypes = [c_void_p, c_void_p]  # (device, service_name?)


def read_message(conn, label=""):
    """Read a message from the ATC connection and print details."""
    msg = ATH.ATHostConnectionReadMessage(conn)
    if not msg:
        print(f"  {label} ReadMessage returned NULL")
        return None, None

    name_cf = ATH.ATCFMessageGetName(msg)
    name = cfstr_to_str(name_cf)
    session = ATH.ATCFMessageGetSessionNumber(msg)
    print(f"  {label} << {name} (session={session})")

    # Dump known params
    for pname in ["GrappaSupportInfo", "ErrorCode", "ManualSync", "_FreeSize",
                   "_PhysicalSize", "Reason", "RequiredVersion", "SyncTypes",
                   "DataClasses", "Application", "Media", "DeviceInfo"]:
        param = ATH.ATCFMessageGetParam(msg, cfstr(pname))
        if param:
            desc = cf_describe(param)
            # Truncate long descriptions
            if len(desc) > 200:
                desc = desc[:200] + "..."
            print(f"       {pname}: {desc}")

    return msg, name


def main():
    # ── Device discovery ──────────────────────────────────────────────────────
    print("[*] Finding device...")
    device_list = MD.AMDCreateDeviceList()
    count = CF.CFArrayGetCount(device_list)
    if count == 0:
        print("[-] No devices. Is iPad connected?")
        return

    device = CF.CFArrayGetValueAtIndex(device_list, 0)
    udid_cf = MD.AMDeviceCopyDeviceIdentifier(device)
    udid = cfstr_to_str(udid_cf)
    print(f"[+] Device: {udid}")

    # Connect
    MD.AMDeviceConnect(device)
    MD.AMDeviceIsPaired(device)
    MD.AMDeviceValidatePairing(device)
    MD.AMDeviceStartSession(device)

    name = cfstr_to_str(MD.AMDeviceCopyValue(device, None, cfstr("DeviceName")))
    ios = cfstr_to_str(MD.AMDeviceCopyValue(device, None, cfstr("ProductVersion")))
    print(f"[+] {name} — iOS {ios}")

    # ── Try starting ATC service directly via MobileDevice ────────────────────
    print("\n[*] Approach A: Start com.apple.atc service via AMDeviceSecureStartService")
    svc_conn = c_void_p()
    err = MD.AMDeviceSecureStartService(device, cfstr("com.apple.atc"), None, byref(svc_conn))
    print(f"    AMDeviceSecureStartService('com.apple.atc'): {err}")
    if svc_conn.value:
        sock = MD.AMDServiceConnectionGetSocket(svc_conn)
        print(f"    Service connection socket: {sock}")

    # Also try atc2
    svc_conn2 = c_void_p()
    err2 = MD.AMDeviceSecureStartService(device, cfstr("com.apple.atc2"), None, byref(svc_conn2))
    print(f"    AMDeviceSecureStartService('com.apple.atc2'): {err2}")

    # ── Approach B: ATHostConnection (let it manage connection) ───────────────
    print("\n[*] Approach B: ATHostConnectionCreateWithLibrary")

    library_id = cfstr("com.apple.iTunes")  # pretend to be iTunes
    device_udid = cfstr(udid)

    conn = ATH.ATHostConnectionCreateWithLibrary(library_id, device_udid, 0)
    if not conn:
        print("[-] ATHostConnectionCreateWithLibrary returned NULL")
        return
    print(f"[+] Connection: {hex(conn)}")

    grappa = ATH.ATHostConnectionGetGrappaSessionId(conn)
    session = ATH.ATHostConnectionGetCurrentSessionNumber(conn)
    print(f"    Initial grappa={grappa}, session={session}")

    # ── Read the initial greeting from device ─────────────────────────────────
    print("\n[*] Reading initial device messages...")

    messages_read = []
    for i in range(10):
        msg, name = read_message(conn, f"[{i+1}]")
        if name is None:
            break
        messages_read.append(name)

        # After receiving Capabilities, check Grappa state
        if name == "Capabilities":
            grappa = ATH.ATHostConnectionGetGrappaSessionId(conn)
            print(f"    → Grappa session after Capabilities: {grappa}")

        # If we got SyncAllowed, try to proceed
        if name == "SyncAllowed":
            print("\n[*] Got SyncAllowed! Checking Grappa state...")
            grappa = ATH.ATHostConnectionGetGrappaSessionId(conn)
            print(f"    Grappa session: {grappa}")
            break

        if name == "SyncFailed":
            print("[-] Got SyncFailed early. Aborting.")
            break

        # After first few messages, try sending HostInfo
        if name == "AssetMetrics" and "HostInfo" not in messages_read:
            print("\n  [*] Sending HostInfo...")
            host_info = CF.CFDictionaryCreateMutable(
                kCFAllocatorDefault, 0,
                kCFTypeDictionaryKeyCallBacks,
                kCFTypeDictionaryValueCallBacks
            )
            CF.CFDictionarySetValue(host_info, cfstr("HostName"), cfstr("mediaporter"))
            CF.CFDictionarySetValue(host_info, cfstr("HostID"), cfstr("com.apple.iTunes"))
            CF.CFDictionarySetValue(host_info, cfstr("Version"), cfstr("12.13.2.3"))
            err = ATH.ATHostConnectionSendHostInfo(conn, host_info)
            print(f"    SendHostInfo: {err} (0x{err & 0xFFFFFFFF:08x})")

    # ── Try sending sync request ──────────────────────────────────────────────
    print("\n[*] Sending sync request...")

    data_classes = CF.CFArrayCreateMutable(kCFAllocatorDefault, 0, kCFTypeArrayCallBacks)
    CF.CFArrayAppendValue(data_classes, cfstr("com.apple.Movies"))

    anchors = CF.CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0,
        kCFTypeDictionaryKeyCallBacks,
        kCFTypeDictionaryValueCallBacks
    )

    err = ATH.ATHostConnectionSendSyncRequest(conn, data_classes, anchors, None)
    print(f"    SendSyncRequest: {err} (0x{err & 0xFFFFFFFF:08x})")

    # Read responses
    print("\n[*] Reading responses...")
    for i in range(5):
        msg, name = read_message(conn, f"[R{i+1}]")
        if name is None:
            break
        if name in ["SyncFailed", "SyncFinished"]:
            break

    # Final grappa state
    grappa = ATH.ATHostConnectionGetGrappaSessionId(conn)
    session = ATH.ATHostConnectionGetCurrentSessionNumber(conn)
    print(f"\n[*] Final state: grappa={grappa}, session={session}")

    # ── Approach C: Try raw ATCFMessage for BeginSync ─────────────────────────
    print("\n[*] Approach C: Send raw ATCFMessage 'BeginSync'")

    params = CF.CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0,
        kCFTypeDictionaryKeyCallBacks,
        kCFTypeDictionaryValueCallBacks
    )

    sync_types = CF.CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0,
        kCFTypeDictionaryKeyCallBacks,
        kCFTypeDictionaryValueCallBacks
    )
    CF.CFDictionarySetValue(sync_types, cfstr("com.apple.Movies"), kCFBooleanTrue)
    CF.CFDictionarySetValue(params, cfstr("SyncTypes"), sync_types)

    msg = ATH.ATCFMessageCreate(session, cfstr("BeginSync"), params)
    if msg:
        print(f"    Created ATCFMessage: {hex(msg)}")
        err = ATH.ATHostConnectionSendMessage(conn, msg)
        print(f"    SendMessage(BeginSync): {err} (0x{err & 0xFFFFFFFF:08x})")

        # Read response
        for i in range(3):
            resp, rname = read_message(conn, f"[B{i+1}]")
            if rname is None or rname in ["SyncFailed", "SyncFinished", "ReadyForSync"]:
                break
    else:
        print("    ATCFMessageCreate returned NULL")

    # Cleanup
    print("\n[*] Cleanup")
    ATH.ATHostConnectionInvalidate(conn)
    ATH.ATHostConnectionRelease(conn)
    print("[+] Done")


if __name__ == '__main__':
    main()
