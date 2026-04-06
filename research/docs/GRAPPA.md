# Grappa Authentication Protocol — Research Findings

**Date:** 2026-04-01 (initial research), updated 2026-04-06
**Context:** RESOLVED. Grappa authentication is solved via replay of a static 84-byte blob (same as hardcoded in `yinyajiang/go-tunes`). The full ATC sync including Grappa works end-to-end. See `CLAUDE.md` and `scripts/atc_proper_sync.py`.

---

## 1. What is Grappa?

"Grappa" is Apple's proprietary challenge-response signing protocol used to authenticate the host-device relationship during ATC (AirTrafficControl) media synchronization sessions. It is **not publicly documented** and has essentially **zero public web presence** — searches for "ATGrappaSession", "apple grappa protocol", "grappa signing iOS", and similar terms return no relevant results outside of iOS runtime header dumps.

**Key facts:**
- Grappa is entirely internal to Apple. No security researcher, blog post, or reverse engineering writeup has been found that discusses it.
- The name "Grappa" does not appear in any FairPlay, SRP, or other known Apple crypto documentation.
- It is not related to FairPlay Streaming DRM (which uses SPC/CKC key exchange).
- It is not related to the iAP2 MFi authentication protocol (which uses the Apple authentication coprocessor).
- It is not related to Apple's GrandSlam authentication protocol (used for Apple ID).

## 2. ATGrappaSession — Runtime Header (Complete)

Found in `nst/iOS-Runtime-Headers` and `MTACS/iOS-17-Runtime-Headers`. The class is **identical across iOS 10, iOS 13, and iOS 17**, suggesting a stable, mature protocol.

**Source:** `PrivateFrameworks/AirTrafficDevice.framework/ATGrappaSession.h`

```objc
@interface ATGrappaSession : NSObject {
    unsigned int  _sessionId;
    NSData * _sessionRequestData;
    NSData * _sessionResponseData;
    unsigned long long  _sessionType;
}

// Session establishment (3-step handshake)
- (id)initWithType:(unsigned long long)arg1;
- (id)establishHostSessionWithDeviceInfo:(id)arg1 clientRequestData:(id*)arg2;
- (id)beginHostSessionWithDeviceResponseData:(id)arg1;
- (id)establishDeviceSessionWithRequestData:(id)arg1 responseData:(id*)arg2;

// Device info exchange
- (id)deviceInfo;

// Signing and verification (post-handshake)
- (id)createSignature:(id*)arg1 forData:(id)arg2;
- (id)verifySignature:(id)arg1 forData:(id)arg2;

// Internal (host vs device role separation)
- (id)_hostCreateSignature:(id*)arg1 forData:(id)arg2;
- (id)_hostVerifySignature:(id)arg1 forData:(id)arg2;
- (id)_deviceCreateSignature:(id*)arg1 forData:(id)arg2;
- (id)_deviceVerifySignature:(id)arg1 forData:(id)arg2;
@end
```

### Handshake Protocol (3 steps)

```
Step 1: Host → Device
  Host calls: establishHostSessionWithDeviceInfo:clientRequestData:
  - Input: deviceInfo (from device's Capabilities message GrappaSupportInfo)
  - Output: clientRequestData (opaque blob to send to device)

Step 2: Device processes request, returns response
  Device calls: establishDeviceSessionWithRequestData:responseData:
  - Input: clientRequestData from Step 1
  - Output: responseData (opaque blob to send back to host)

Step 3: Host finalizes session
  Host calls: beginHostSessionWithDeviceResponseData:
  - Input: responseData from Step 2
  - Session is now established; signing/verification available
```

### Session Properties
- `_sessionId` (uint32) — Unique session identifier, stored as `_grappaId` in ATLegacyDeviceSyncManager
- `_sessionType` (uint64) — Initialized via `initWithType:` (values unknown, likely 0 or 1)
- `_sessionRequestData` / `_sessionResponseData` — Opaque blobs exchanged during handshake

### Post-Handshake Signing
After the 3-step handshake, every ATC message's parameters and payload are signed:
- `createSignature:forData:` — Produces a signature (NSData) for a given data blob
- `verifySignature:forData:` — Verifies a signature against data
- Separate internal methods for host vs. device role

## 3. ATGrappaSignatureProvider

```objc
@interface ATGrappaSignatureProvider : ATSignatureProvider {
    ATGrappaSession * _grappaSession;
    ATDeviceSettings * _settings;
}

- (id)initWithGrappaSession:(id)arg1;
- (id)createSignature:(id*)arg1 forData:(id)arg2;
- (id)verifySignature:(id)arg1 forData:(id)arg2;
@end
```

This is a wrapper that connects an ATGrappaSession to the ATConcreteMessageLink's `signatureProvider` property. Once set, all messages sent/received through the link are automatically signed/verified.

## 4. ATSignatureProvider (Base Class)

```objc
@interface ATSignatureProvider : NSObject
- (id)createSignature:(id*)arg1 forData:(id)arg2;
- (id)verifySignature:(id)arg1 forData:(id)arg2;
@end
```

### Known Subclasses
- **ATGrappaSignatureProvider** — Current, uses Grappa session for HMAC/signing
- **ATMD5SignatureProvider** — Legacy fallback (MD5-based, no session required)

```objc
@interface ATMD5SignatureProvider : ATSignatureProvider
- (id)createSignature:(id*)arg1 forData:(id)arg2;
- (id)verifySignature:(id)arg1 forData:(id)arg2;
@end
```

**Critical observation:** ATMD5SignatureProvider has no ivars — it doesn't need a session or key exchange. It likely uses a static/derived key with MD5-HMAC. This could be exploitable on older devices that still accept it.

## 5. ATConcreteMessageLink — Where Signing Happens

```objc
@interface ATConcreteMessageLink : ATMessageLink <ATSocketDelegate> {
    // ...
    ATSignatureProvider * _signatureProvider;
    ATMessageParser * _parser;
    // ...
}
@property (nonatomic, retain) ATSignatureProvider *signatureProvider;
```

The `signatureProvider` property is set after the Grappa handshake completes. All subsequent `_sendMessage:error:` calls use it to produce `paramsSignature` and `payloadSignature` fields in ATPMessage.

## 6. ATPMessage — Protobuf Wire Format (Complete)

```objc
@interface ATPMessage : PBCodable <NSCopying> {
    unsigned int  _messageID;
    int  _messageType;
    unsigned int  _sessionID;
    bool  _additionalPayload;
    NSData * _parameters;      // Binary plist of command params
    NSData * _paramsSignature;  // Grappa signature of _parameters
    NSData * _payload;          // File data (for transfers)
    NSData * _payloadSignature; // Grappa signature of _payload
    ATPRequest * _request;
    ATPResponse * _response;
    ATPError * _streamError;
}
```

### ATPRequest
```objc
@interface ATPRequest : PBRequest <NSCopying> {
    NSString * _command;    // e.g., "BeginSync", "SyncData"
    NSString * _dataClass;  // e.g., "com.apple.media"
}
```

### ATPResponse
```objc
@interface ATPResponse : PBCodable <NSCopying> {
    ATPError * _error;
}
```

### ATPError
```objc
@interface ATPError : PBCodable <NSCopying> {
    int  _code;             // Error code (e.g., 12)
    NSString * _domain;     // Error domain string
    long long  _domainCode; // Domain-specific code
    NSString * _errorDescription;
}
```

## 7. ATLegacyDeviceSyncManager — Grappa Integration Point

```objc
@interface ATLegacyDeviceSyncManager : ATDeviceSyncManager {
    unsigned int  _grappaId;  // Session ID from Grappa handshake
    ATLegacyMessageLink * _currentMessageLink;
    // ...
}

// Message handlers (these are the ATC protocol commands):
- (void)_handleCapabilitiesMessage:(id)arg1 fromLink:(id)arg2;
- (void)_handleHostInfoMessage:(id)arg1 fromLink:(id)arg2;
- (void)_handleRequestingSyncMessage:(id)arg1 fromLink:(id)arg2;
- (void)_handleSyncFailedMessage:(id)arg1 fromLink:(id)arg2;
- (void)_handleSyncStatusMessage:(id)arg1 fromLink:(id)arg2;
- (void)_handleAssetMetricsMessage:(id)arg1 fromLink:(id)arg2;
- (void)_handleFinishedSyncingMetadataMessage:(id)arg1 fromLink:(id)arg2;
```

The `_grappaId` field confirms that Grappa session ID is tracked at the sync manager level. The `_handleCapabilitiesMessage:fromLink:` method is where the `GrappaSupportInfo` dict is processed and the Grappa handshake is initiated.

## 8. GrappaSupportInfo Exchange

From our observed ATC conversation:

```
Device → Host: Capabilities
  Params.GrappaSupportInfo: {
    version: 1,
    deviceType: 0,        // 0 = device (iPad/iPhone)
    protocolVersion: 1
  }

Host → Device: Capabilities (response)
  Params.GrappaSupportInfo: {
    version: 1,
    deviceType: 1,        // 1 = host (macOS/Windows)
    protocolVersion: 1
  }
```

The `GrappaSupportInfo` dictionary establishes that both sides support Grappa v1. The actual handshake data is exchanged in subsequent messages (not yet observed — this happens between Capabilities and BeginSync in the Finder flow).

## 9. com.apple.atc vs com.apple.atc2

### Services.plist Definitions

Both services are defined in `/System/Library/Lockdown/Services.plist`:

- **com.apple.atc** — Original ATC service (iOS 6+), runs as user "mobile", XPCServiceName "com.apple.atc", AllowUnactivatedService: true
- **com.apple.atc2** — Newer variant (likely iOS 10+), presumably uses modern protobuf transport

### RemoteXPC Variants (iOS 17+)
- `com.apple.atc.shim.remote` — Port 49617
- `com.apple.atc2.shim.remote` — Port 49612
- Both require `com.apple.mobile.lockdown.remote.trusted` entitlement

### Key Difference (Inferred)
- **atc** uses legacy plist-based messages (ATLegacyMessageLink, ATLegacyDeviceSyncManager)
- **atc2** likely uses protobuf-based messages (ATConcreteMessageLink, ATPMessage with ATMessageParser)
- Both require Grappa authentication (ATGrappaSignatureProvider is framework-wide, not service-specific)

**Testing atc2 may not bypass Grappa** — both services appear to use the same ATGrappaSession infrastructure.

## 10. Grappa and the Lockdown Pairing Record

**Finding: No direct relationship found.**

The lockdown pairing record contains:
- 2048-bit RSA public keys (host and device)
- A 256-bit key for the escrow keybag
- TLS certificates for the lockdown SSL session

Grappa appears to operate at a **higher layer** — it runs inside the already-TLS-encrypted ATC session. The pairing record provides the transport security; Grappa provides application-level message authentication specific to ATC sync.

**Speculation:** Grappa keys may be derived from:
1. The device's DSID (Apple ID-related device identifier stored in com.apple.atc preferences)
2. A hardware-bound key (Secure Enclave)
3. A shared secret established during the first iTunes pairing (stored in device keychain)
4. Some combination of the lockdown session keys and device identity

## 11. IC-Info.sidf / IC-Info.sidv Files

These files live in `/iTunes_Control/iTunes/` on the device and are part of the ATC sync state:

- **IC-Info.sidf** — Likely "sync info - full" (complete sync state)
- **IC-Info.sidv** — Likely "sync info - version" (sync version/generation counter)
- **IC-Info.sidb** — Sync database

Format: Binary, proprietary. Forensic researchers have not been able to parse IC-Info.sidv. These files are managed by the ATC daemon (atcd/AirTrafficDevice) and are not directly user-accessible.

**Relevance to Grappa:** These files may store the Grappa session state or derived keys from previous successful syncs.

## 12. AirTrafficDevice Privacy Leak (2025)

**Source:** paradisefacade.com blog post (October 2025)

The AirTrafficDevice framework's `com.apple.atc` preferences domain was found to be **unprotected**, leaking all DSIDs (Apple ID device identifiers) required to play media and use downloaded apps. This was fixed in iOS 18.7 and iOS 26 by locking down the preferences domain.

**Relevance:** The DSIDs stored in com.apple.atc preferences may be inputs to the Grappa key derivation process. If Grappa derives its signing key from the DSID, we would need to read this value (which is now protected in newer iOS).

## 13. IPSW Extraction Path

To get the actual AirTrafficDevice binary for disassembly:

```bash
# Install ipsw tool
brew install blacktop/tap/ipsw

# Download IPSW for iPad (8th gen, iPadOS 18.x)
ipsw download ipsw --device iPad8,7 --version 18.1

# Extract dyld_shared_cache
ipsw extract --dyld <ipsw_file>

# Extract AirTrafficDevice framework from shared cache
ipsw dyld extract <path/to/dyld_shared_cache> AirTrafficDevice

# Dump ObjC headers (verification)
ipsw dyld objc dump <path/to/dyld_shared_cache> AirTrafficDevice

# Or dump specific class
ipsw dyld objc class <path/to/dyld_shared_cache> ATGrappaSession
```

The extracted binary can be loaded into Ghidra or IDA Pro to reverse engineer the actual Grappa algorithm (initWithType:, establishHostSessionWithDeviceInfo:clientRequestData:, createSignature:forData:).

## 14. Frida Hooking Approach

No existing Frida scripts for ATGrappaSession were found online. A custom approach:

### On macOS (hook Finder/AMPDevicesAgent during sync)
```javascript
// Attach to AMPDevicesAgent
// Hook MobileDevice.framework or AirTraffic.framework calls

// Key classes to hook on macOS side:
// ATGrappaSession -establishHostSessionWithDeviceInfo:clientRequestData:
// ATGrappaSession -beginHostSessionWithDeviceResponseData:
// ATGrappaSession -createSignature:forData:
// ATSignatureProvider -createSignature:forData:
```

### On iOS (requires jailbreak)
```javascript
// Hook AirTrafficDevice.framework in atcd daemon
// ATGrappaSession -establishDeviceSessionWithRequestData:responseData:
// ATGrappaSession -deviceInfo
```

### XPC Tracing
The `miticollo/xpc-tracer` GitHub tool is a Frida-based XPC message tracer that works on both iOS and macOS. This could capture the XPC calls between Finder, AMPDevicesAgent, and the ATC service.

## 15. AMPDevicesAgent (macOS)

AMPDevicesAgent is the macOS daemon (introduced in Catalina) that handles all iOS device sync operations. It replaced the in-process iTunes sync logic.

- Handles protocol-level conversations with iOS devices over USB and network
- Negotiates pairing, enumerates devices
- Forwards requests to Finder for device browsing
- **Already has valid Grappa credentials** — it performs the Grappa handshake as part of normal Finder sync

**Potential bypass:** If we can call AMPDevicesAgent's XPC interface directly with our media data, it would handle Grappa internally and we never need to implement it ourselves.

## 16. libimobiledevice Status

**ATC is NOT implemented** in libimobiledevice. From issue #735 (2022):
- "media synchronization is not supported in libimobiledevice"
- From issue #133 (2014): "It's quite a mess and only valuable to work on if you are good at encryption" (Martin Szulecki, maintainer)
- No one has contributed an ATC implementation in 10+ years
- pymobiledevice3 also does not implement ATC/media sync

This confirms that Grappa is a significant barrier — even experienced iOS protocol implementors have not tackled it.

## 17. Summary of Crypto Analysis

### What We Know
1. Grappa is a 3-step challenge-response handshake
2. It produces session-bound signing keys
3. It signs both `parameters` (plist command data) and `payload` (file data) separately
4. The session has a type (uint64) and ID (uint32)
5. Both host and device have distinct sign/verify implementations
6. There is a legacy fallback (ATMD5SignatureProvider) with no session requirement

### What We Don't Know
1. The actual crypto algorithm (HMAC-SHA256? AES-CMAC? Custom?)
2. The key derivation inputs (DSID? Hardware key? Pairing record?)
3. The format of the exchanged blobs (clientRequestData, responseData)
4. Whether ATMD5SignatureProvider is still accepted by modern iOS
5. The relationship between `_sessionType` values and crypto parameters

### Difficulty Assessment
**HIGH.** Grappa is:
- Completely undocumented
- Never publicly reverse-engineered
- Likely uses hardware-bound keys (Secure Enclave)
- The #1 reason libimobiledevice never implemented media sync

## 18. Recommended Next Steps (Prioritized)

### Tier 1: Bypass Grappa entirely
1. **AMPDevicesAgent XPC** — Call macOS AMPDevicesAgent directly to trigger sync. It handles Grappa internally. This is the most promising path. See `docs/XPC_APPROACH.md`.
2. **cfgutil** — Apple Configurator CLI may expose media install functionality without requiring Grappa implementation.

### Tier 2: Capture Grappa in action
3. **Frida hook AMPDevicesAgent** — Intercept the Grappa handshake blobs during a real Finder sync. Capture clientRequestData, responseData, and resulting signatures. This reveals the wire format.
4. **LLDB on AMPDevicesAgent** — Set breakpoints on ATGrappaSession methods, inspect all arguments and return values.

### Tier 3: Reverse engineer Grappa
5. **Extract AirTrafficDevice binary from IPSW** — Use `ipsw` tool to get the Mach-O binary, load in Ghidra, reverse the actual algorithm.
6. **Test ATMD5SignatureProvider** — If iOS still accepts MD5 signatures, this is much simpler to implement (static key, MD5-HMAC).

### Tier 4: Alternative protocols
7. **Try com.apple.atc2** — May have different auth requirements (unlikely but worth testing).
8. **Explore AFC + medialibraryd notification** — Write files via AFC and find a way to trigger medialibraryd to scan them (may not create proper TV app entries).

---

## AirFair Discovery (2026-04-01 Live Testing)

The Grappa signing mechanism is internally called **"AirFair"**. Found via strings in AMPDevicesAgent binary:

### Key Strings
```
afsync.rq.sig                              — AirFair sync request signature file
afsync.rs.sig                              — AirFair sync response signature file
airtraffic> failed to find AirFair request signature file (%d)
airtraffic> failed to find AirFair sync folder (%d)
airtraffic> failed to read AirFair request file
airtraffic> failed to save AirFair response signature file (%d)
airtraffic> GrappaHostSign failed (%d) with session id %u
airtraffic> GrappaHostVerify failed (%d) with session id %u
handlerData->deviceInfo.supportsAirFairKeybag
```

### Device Filesystem
- `AirFair/sync/` directory exists on device (via AFC) — empty between syncs
- During sync, `afsync.rq.sig` and `afsync.rs.sig` are created/read
- `supportsAirFairKeybag` suggests a keybag (crypto key container) is involved

### Live Protocol Testing Results

1. **Grappa v0 (legacy)** — Device still follows normal flow but RequestingSync returns SyncFailed ErrorCode 12
2. **GrappaSessionRequest command** — Device ignores it (timeout)
3. **EstablishGrappaSession command** — Device responds with Ping (doesn't understand)
4. **GrappaSessionRequest in Capabilities.Params** — Device ignores the field

The Grappa handshake is NOT a separate command. It's likely embedded in the Capabilities exchange or happens before/after via the AirFair files on disk.

## Sources

### Runtime Headers
- [nst/iOS-Runtime-Headers (GitHub)](https://github.com/nst/iOS-Runtime-Headers) — ATGrappaSession.h, ATGrappaSignatureProvider.h, ATMD5SignatureProvider.h, ATLegacyDeviceSyncManager.h, ATLegacyMessageLink.h
- [MTACS/iOS-17-Runtime-Headers (GitHub)](https://github.com/MTACS/iOS-17-Runtime-Headers) — ATGrappaSession.h, ATDeviceService.h, ATPMessage.h, ATConcreteMessageLink.h, ATMessageParser.h, ATSignatureProvider.h, ATPRequest.h, ATPResponse.h, ATPError.h
- [Limneos iOS Runtime Headers](https://developer.limneos.net/?ios=14.4&framework=AirTrafficDevice.framework) — AirTrafficDevice framework browser

### ATC Protocol / libimobiledevice
- [libimobiledevice ATC issue #735](https://github.com/libimobiledevice/libimobiledevice/issues/735) — "media synchronization is not supported"
- [libimobiledevice DBVersion 5 issue #133](https://github.com/libimobiledevice/libimobiledevice/issues/133) — "quite a mess, only valuable if you are good at encryption"
- [SDMMobileDevice ATC issue #61](https://github.com/samdmarshall/SDMMobileDevice/issues/61) — "I don't think I have that protocol documented"

### Lockdown Services
- [iPhone Wiki: Services.plist](https://www.theiphonewiki.com/wiki//System/Library/Lockdown/Services.plist) — com.apple.atc, com.apple.atc2 definitions
- [The Apple Wiki: Services](https://theapplewiki.com/wiki/Services) — Service descriptions

### AirTrafficDevice Security
- [AirTrafficDevice Privacy Leak](https://paradisefacade.com/blog/2025/10/28/airtrafficdevice-ignored-reluctantly-fixed-no-cve-no-bounty-a-story-of-a-serious-privacy-leak-in-ios) — com.apple.atc preferences domain unprotected, leaking DSIDs

### IPSW / Reverse Engineering
- [blacktop/ipsw (GitHub)](https://github.com/blacktop/ipsw) — iOS/macOS Research Swiss Army Knife
- [ipsw dyld_shared_cache guide](https://blacktop.github.io/ipsw/docs/guides/dyld/) — Extracting frameworks from IPSW

### XPC / AMPDevicesAgent
- [miticollo/xpc-tracer (GitHub)](https://github.com/miticollo/xpc-tracer) — Frida-based XPC message tracer
- [AMPDevicesAgent explained (George Garside)](https://georgegarside.com/blog/macos/stop-finder-opening-when-connecting-iphone/)
- [Intercepting macOS XPC with Frida](https://infosecwriteups.com/intercepting-macos-xpc-e11103dacafd)
- [Advanced Frida Usage: Inspecting XPC Calls](https://medium.com/@8ksec/advanced-frida-usage-part-3-inspecting-xpc-calls-76ae6884d95b)

### Protocol Context
- [pymobiledevice3 protocol layers](https://github.com/doronz88/pymobiledevice3/blob/master/misc/understanding_idevice_protocol_layers.md)
- [pymobiledevice3 RemoteXPC docs](https://github.com/doronz88/pymobiledevice3/blob/master/misc/RemoteXPC.md)
- [Understanding usbmux and iOS lockdown](https://jon-gabilondo-angulo-7635.medium.com/understanding-usbmux-and-the-ios-lockdown-service-7f2a1dfd07ae)
