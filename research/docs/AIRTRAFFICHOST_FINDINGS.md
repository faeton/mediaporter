# AirTrafficHost.framework — Research Findings

**Date:** 2026-04-02
**Status:** Framework exploration PoC. Grappa generation from the framework requires code signing entitlements, but we solved this via Grappa replay (84-byte static blob). See `CLAUDE.md` for the full working solution.

## Key Discovery

`AirTrafficHost.framework` is a real, loadable private framework at:
- `/System/Library/PrivateFrameworks/AirTrafficHost.framework/AirTrafficHost`
- `/Library/Apple/System/Library/PrivateFrameworks/AirTrafficHost.framework/Versions/A/AirTrafficHost`

It exports ~60 C functions (universal binary: x86_64 + arm64e) for complete ATC media sync.

## What Works

### MobileDevice.framework (no sudo, no tunnel!)
```python
import ctypes
MD = ctypes.cdll.LoadLibrary('/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice')

# These ALL work from an unsigned Python process:
MD.AMDCreateDeviceList()              # → finds iPad via usbmuxd
MD.AMDeviceConnect(device)            # → 0 (success)
MD.AMDeviceValidatePairing(device)    # → 0
MD.AMDeviceStartSession(device)       # → 0
MD.AMDeviceCopyDeviceIdentifier(device)  # → UDID string
MD.AMDeviceCopyValue(device, ...)     # → device name, iOS version, etc.

# Start ATC service — WORKS for both atc and atc2!
MD.AMDeviceSecureStartService(device, "com.apple.atc", None, &svc_conn)  # → 0
MD.AMDeviceSecureStartService(device, "com.apple.atc2", None, &svc_conn) # → 0
# Both return valid SSL-wrapped connections with real socket FDs
```

### AirTrafficHost connection
```python
ATH = ctypes.cdll.LoadLibrary('/System/Library/PrivateFrameworks/AirTrafficHost.framework/AirTrafficHost')

conn = ATH.ATHostConnectionCreateWithLibrary(library_id, device_udid, 0)  # → valid handle
# Framework automatically connects to device and initiates ATC protocol
# We receive: InstalledAssets, AssetMetrics, SyncAllowed
```

### Raw ATC protocol via service connection
Sending/receiving plist messages through `AMDServiceConnectionSend/Receive` works perfectly:
- Device sends Capabilities with `GrappaSupportInfo: {version: 1, deviceType: 0, protocolVersion: 1}`
- We can respond with Capabilities
- Device sends InstalledAssets, AssetMetrics, SyncAllowed
- We can send HostInfo, RequestingSync

## What Fails

### Grappa authentication
**All paths hit the same wall: ErrorCode 12 (Grappa auth required)**

1. **ATHostConnection Send functions** return error `0x80f20840` — the framework loads CoreFP (FairPlay) but can't complete the Grappa key exchange
2. **Raw protocol messages** get `SyncFailed: ErrorCode 12, RequiredVersion 10.5.0.115` when sending `RequestingSync` or `BeginSync`

### Root Cause: FairPlay daemon entitlement

AMPDevicesAgent has `com.apple.private.fpsd.client` entitlement — this grants access to `fairplayd` (the FairPlay Server Daemon). Our Python process does NOT have this entitlement.

Three FairPlay daemons running on macOS:
- `fairplayd` (CoreFP) — main FairPlay daemon
- `fairplaydeviceidentityd` — device identity
- `adid` (CoreADI) — Apple Device Identity

The CoreFP output when we try to use AirTrafficHost:
```
################ Library Path =/System/Library/PrivateFrameworks/CoreFP.framework/CoreFP
################ About to find appHelloImp
################ About to find appSetupSessionImp
################ About to find runCommandImp
################ About to find getDLLVersionImp
################ About to find teardownImp
```

CoreFP loads and tries to find its implementation functions, but the FairPlay session can't be established without `fpsd.client` entitlement.

### AMPDevicesAgent XPC also blocked

`AMPDevicesClient.fetchDeviceIdentifiersWithReply:` fails with:
```
NSCocoaErrorDomain Code=4097 "connection to service named com.apple.amp.devicesd"
```

Error 4097 = NSXPCConnectionInterrupted — entitlement check failed.
Required: `com.apple.amp.devices.client` entitlement (Apple code-signed only).

## AMPDevicesAgent Full Entitlements

```
adi-client: 409835401
com.apple.amp.artwork.client: true
com.apple.amp.devices.client: true     ← XPC access
com.apple.amp.library.client: true
com.apple.private.fpsd.client: true    ← FairPlay daemon
com.apple.private.accounts.allaccounts: true
com.apple.private.bookkit: true
com.apple.private.sqlite.sqlite-encryption: true
com.apple.security.files.user-selected.read-write: true
keychain-access-groups: [apple]
```

## Exported Functions (AirTrafficHost)

### Connection lifecycle
- `ATHostConnectionCreateWithLibrary(library_id, device_udid, flags)` → connection handle
- `ATHostConnectionCreate(library_id, device_udid, flags)`
- `ATHostConnectionCreateWithCallbacks(library_id, device_udid, callbacks)`
- `ATHostConnectionCreateWithQueryCallback(library_id, device_udid, callback, userdata)`
- `ATHostConnectionDestroy(conn)`
- `ATHostConnectionRetain/Release(conn)`
- `ATHostConnectionInvalidate(conn)`

### Session info
- `ATHostConnectionGetGrappaSessionId(conn)` → uint32 (getter — Grappa handled internally)
- `ATHostConnectionGetCurrentSessionNumber(conn)` → uint32

### Send functions
- `ATHostConnectionSendHostInfo(conn, dict)`
- `ATHostConnectionSendPowerAssertion(conn, bool)`
- `ATHostConnectionSendSyncRequest(conn, dataclasses, anchors, opts)`
- `ATHostConnectionSendMetadataSyncFinished(conn, status, summary)`
- `ATHostConnectionSendFileBegin(conn, info)`
- `ATHostConnectionSendFileProgress(conn, info)`
- `ATHostConnectionSendAssetCompleted(conn, asset_id, dataclass, info)`
- `ATHostConnectionSendAssetCompletedWithMetadata(conn, ...)`
- `ATHostConnectionSendMessage(conn, ATCFMessage)`
- `ATHostConnectionSendPing(conn)`
- `ATHostConnectionSendSyncFailed(conn, ...)`
- `ATHostConnectionSendStatusMessage(conn, ...)`
- `ATHostConnectionSendAssetMetricsRequest(conn)`
- `ATHostConnectionSendConnectionInvalid(conn)`

### Read
- `ATHostConnectionReadMessage(conn)` → ATCFMessage

### Message helpers
- `ATCFMessageCreate(session, command, params)` → ATCFMessage
- `ATCFMessageGetName(msg)` → CFString
- `ATCFMessageGetParam(msg, key)` → CFType
- `ATCFMessageGetSessionNumber(msg)` → uint32
- `ATCFMessageVerify(msg)` → bool (signature verification)

### Device socket
- `ATHostAMDeviceSocketCreate(...)` → socket
- `ATHostAMDeviceSocketDestroy(socket)`
- `ATHostAMDeviceSocketWrite(socket, data, len)`
- `ATHostCreateDeviceServiceConnection(device, service_name)`

### Notification
- `ATHostDeviceNotificationObserverCreate/Destroy`
- `ATHostDeviceObserverCreate/Destroy/IsAttached`

### Message link
- `ATHostMessageLinkCreate/Destroy/SendMessage`
- `ATHostWaitForQueueToDrain`

## Resolution

The Grappa generation blocker was resolved via replay of a static 84-byte blob (found in the open-source `yinyajiang/go-tunes` project). Dynamic Grappa generation from the framework is not needed. Full end-to-end sync works using the high-level ATHostConnection API with the replayed blob.
