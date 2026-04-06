---
title: "AMPDevicesAgent XPC Interface Research"
date: 2026-04-01
status: research
tags: [xpc, ampdevices, media-sync, ios, macos, reverse-engineering]
---

# AMPDevicesAgent XPC Interface Research

## Executive Summary

AMPDevicesAgent is the macOS per-user daemon that Finder delegates all iOS device sync/backup operations to (introduced in macOS Catalina when iTunes was decomposed). It communicates via NSXPCConnection using the `AMPDevicesProtocol`. Class-dump headers exist for this protocol and reveal methods directly relevant to our use case -- notably `copyFiles:toDevice:withReply:` and `copyObjects:toDevice:withReply:`. However, connecting to this XPC service from a third-party process almost certainly requires Apple-signed entitlements, making direct XPC calls infeasible without code injection or entitlement spoofing.

---

## 1. AMPDevicesAgent Overview

- **Binary location:** `/System/Library/PrivateFrameworks/AMPDevices.framework/Versions/A/Support/AMPDevicesAgent`
- **Framework:** `/System/Library/PrivateFrameworks/AMPDevices.framework/`
- **launchd identifier:** `com.apple.AMPDevicesAgent`
- **Restart command:** `sudo launchctl kickstart -k system/com.apple.AMPDevicesAgent`
- **Role:** Per-user daemon managing all iOS/iPadOS/tvOS device communication -- pairing, enumeration, sync, backup, restore, software update, file sharing. Finder is its primary client.
- **Related daemons:**
  - `AMPDeviceDiscoveryAgent` -- discovers devices over Wi-Fi/USB
  - `AMPLibraryAgent` -- per-user daemon managing media libraries for Music.app and TV.app
  - `AMPArtworkAgent` -- artwork cache management
  - `remoted` -- Remote Service Discovery daemon (QUIC+RemoteXPC, iOS 17+)
  - `usbmuxd` -- USB multiplexing daemon at `/var/run/usbmuxd`

---

## 2. AMPDevicesProtocol -- Complete XPC Interface

Source: [w0lfschild/macOS_headers](https://github.com/w0lfschild/macOS_headers/blob/master/macOS/PrivateFrameworks/AMPDevices/15/AMPDevicesProtocol-Protocol.h) (version 15 = macOS Ventura/Sonoma era)

### 2.1 Methods Directly Relevant to Media Sync

```objc
// THE KEY METHODS for our use case:
- (void)copyFiles:(NSArray *)arg1 toDevice:(AMPDevice *)arg2 withReply:(void (^)(NSError *))arg3;
- (void)copyObjects:(NSArray *)arg1 toDevice:(AMPDevice *)arg2 withReply:(void (^)(NSError *))arg3;
- (void)canAcceptFiles:(NSArray *)arg1 forDevice:(AMPDevice *)arg2 withReply:(void (^)(BOOL, NSError *))arg3;
- (void)canAcceptObjects:(NSArray *)arg1 forDevice:(AMPDevice *)arg2 withReply:(void (^)(BOOL, NSError *))arg3;
- (void)deleteObjects:(NSArray *)arg1 fromDevice:(AMPDevice *)arg2 withReply:(void (^)(NSError *))arg3;
```

These are exactly what Finder calls when you drag-and-drop video files onto the device sidebar. `copyFiles:` likely accepts an NSArray of NSURL file paths; `copyObjects:` likely accepts media library object references.

### 2.2 Sync Lifecycle Methods

```objc
- (NSProgress *)startSyncForDevice:(AMPDevice *)arg1 withOptions:(unsigned long long)arg2 withReply:(void (^)(NSError *))arg3;
- (void)stopSyncForDevice:(AMPDevice *)arg1 withReply:(void (^)(NSError *))arg2;
- (NSProgress *)registerForSyncProgressForDevice:(AMPDevice *)arg1 withReply:(void (^)(NSError *))arg2;
- (void)isSyncInProgressForDevice:(AMPDevice *)arg1 withReply:(void (^)(BOOL, NSError *))arg2;
- (void)isSyncAllowedForDevice:(AMPDevice *)arg1 withReply:(void (^)(BOOL, NSError *))arg2;
- (void)checkForSyncWhenConnectedForDevice:(AMPDevice *)arg1 withReply:(void (^)(NSError *))arg2;
- (void)fetchSyncErrorsForDevice:(AMPDevice *)arg1 withReply:(void (^)(NSArray *, NSError *))arg2;
- (void)hasSyncErrorsForDevice:(AMPDevice *)arg1 withReply:(void (^)(BOOL, NSError *))arg2;
```

### 2.3 Sync Preferences (controls what content syncs)

```objc
- (void)setSyncPrefs:(AMPDeviceSyncPrefs *)arg1 forDevice:(AMPDevice *)arg2 withReply:(void (^)(NSError *, BOOL))arg3;
- (void)fetchSettingsForDevice:(AMPDevice *)arg1 withReply:(void (^)(AMPDeviceInfo *, AMPDeviceSyncPrefs *, NSError *))arg2;
```

`AMPDeviceSyncPrefs` has ~140 properties including:
- `syncMovies` / `syncTVShows` / `syncPodcasts` (BOOL flags)
- Selected playlists, artists, albums, genres (NSSet/NSArray)
- `wifiSync`, `diskMode`, `cloudBackup` flags
- Photo sync preferences via `AMPPhotoSyncPrefs`

### 2.4 Device Discovery and Enumeration

```objc
- (void)fetchDeviceIdentifiersWithReply:(void (^)(NSArray *, NSError *))arg1;
- (void)configureNewDevice:(AMPDevice *)arg1 withReply:(void (^)(NSError *))arg2;
- (void)ejectDevice:(AMPDevice *)arg1 withReply:(void (^)(NSError *))arg2;
- (void)revealDeviceInFinder:(AMPDevice *)arg1 withReply:(void (^)(NSError *))arg2;
```

### 2.5 File Sharing (App Documents)

```objc
- (void)fetchFileSharingAppsForDevice:(AMPDevice *)arg1 withReply:(void (^)(NSArray *, NSError *))arg2;
- (void)fetchFileSharingItemsForApp:(NSString *)arg1 forDevice:(AMPDevice *)arg2 withReply:(void (^)(NSArray *, NSError *))arg3;
- (NSProgress *)copyItemAtURL:(NSURL *)arg1 toURL:(NSURL *)arg2 withReply:(void (^)(NSDictionary *, NSError *))arg3;
- (NSProgress *)moveItemAtURL:(NSURL *)arg1 toURL:(NSURL *)arg2 withReply:(void (^)(NSDictionary *, NSError *))arg3;
- (void)deleteItemAtURL:(NSURL *)arg1 withReply:(void (^)(NSError *))arg2;
- (void)renameItemAtURL:(NSURL *)arg1 to:(NSString *)arg2 withReply:(void (^)(NSDictionary *, NSError *))arg3;
```

### 2.6 Backup/Restore (not directly relevant but documents protocol shape)

Full backup, restore, password management, and archive methods are also exposed.

---

## 3. Supporting Classes

### AMPDevice (NSSecureCoding, NSCopying)

Key properties: `deviceName`, `deviceIdentifier`, `deviceClass`, `productType`, `uniqueIdentifier`, `userSerialNumber`, `ECID`, `productVersion`, `totalDataCapacity`, `deviceImage`, `needsPairing`, `connectedViaWifi`.

### AMPDevicesClient

The client-side XPC wrapper. Holds an `NSXPCConnection *_connection` and `NSHashTable *_listeners`. Implements both `AMPDevicesProtocol` and `AMPDevicesClientEventsProtocol`. Methods: `connect`, `disconnect`, `currentConnection`, `addListener:`, `removeListener:`.

### AMPDevicesClientEventsProtocol (callbacks)

```objc
- (void)didStartSyncForDeviceWithIdentifier:(NSString *)arg1;
- (void)didCompleteSyncForDeviceWithIdentifier:(NSString *)arg1 withError:(NSError *)arg2;
- (void)didChangeSyncAllowedState:(BOOL)arg1 forDeviceWithIdentifier:(NSString *)arg2;
- (void)didChangeDeviceSyncPrefs:(AMPDeviceSyncPrefs *)arg1 forDeviceWithIdentifier:(NSString *)arg2;
// ... ~30 event methods total
```

### DeviceViewConnection

Uses two `NSXPCConnection` instances (`sideConnection` and `connectionToDiscoveryService`), plus a `DeviceRemoteViewController` for Finder's sidebar UI.

### Header Source

All 48+ headers available at:
- Version 1.0.0 (Catalina): https://github.com/w0lfschild/macOS_headers/tree/master/macOS/PrivateFrameworks/AMPDevices/1.0.0
- Version 15 (Ventura+): https://github.com/w0lfschild/macOS_headers/tree/master/macOS/PrivateFrameworks/AMPDevices/15

---

## 4. The Entitlement Problem

### Why Third-Party XPC Connections Will Fail

Apple's XPC services validate connecting clients via code-signing requirements. AMPDevicesAgent almost certainly requires:

1. **Apple code signature** -- the connecting binary must be signed by Apple (Finder is).
2. **Specific entitlements** -- likely `com.apple.amp.*` or `com.apple.private.amp.*` entitlements that Apple does not grant to third parties.

macOS XPC services can enforce these via:
- `xpc_connection_set_peer_entitlement_exists_requirement()`
- `xpc_connection_set_peer_entitlement_matches_value_requirement()`
- Code signing audit tokens checked at connection acceptance

### Theoretical Bypasses (all problematic)

| Approach | Feasibility | Risk |
|----------|-------------|------|
| Disable SIP + inject into Finder | Works but requires SIP disabled | Unacceptable for production |
| Enterprise certificate with com.apple.* entitlements | Theoretically possible | Apple will revoke the certificate |
| DYLIB injection into AMPDevicesAgent | Requires SIP disabled | Same as above |
| Proxy via AppleScript/Finder automation | Finder has no scriptable sync API | Dead end |

**Verdict: Direct XPC to AMPDevicesAgent is not viable for a shipping product.**

---

## 5. The com.apple.atc (AirTrafficControl) Service

### What It Is

`com.apple.atc` is the iOS lockdown service responsible for media content transfer (music, video, podcasts). It runs on the iOS device side.

- Defined in `/System/Library/Lockdown/Services.plist` on iOS
- XPC service name: `com.apple.atc`
- Runs under mobile user
- Allows unactivated service access
- Modern variants: `com.apple.atc.shim.remote` and `com.apple.atc2.shim.remote` (iOS 17+ RemoteXPC)

### The Grappa Authentication Problem

When macOS connects to `com.apple.atc` via `AMDeviceStartService()`, the service requires a proprietary cryptographic handshake known informally as "Grappa" authentication. This is:

- Not documented by Apple
- Not implemented in libimobiledevice or pymobiledevice3
- Handled transparently by Apple's MobileDevice.framework internals
- The reason no open-source tool can directly sync media to the TV/Music app

The SDMMobileDevice project confirmed: "I don't think I have that protocol documented" regarding com.apple.atc.

---

## 6. RemoteXPC / remoted (iOS 17+)

iOS 17 introduced a refactored communication stack:

- **Protocol:** QUIC + HTTP/2 with XPC dictionaries serialized over HTTP/2
- **Discovery port:** 58783 (untrusted)
- **Pairing:** SRP key exchange, then QUIC/TLS VPN tunnel
- **ATC services visible:** `com.apple.atc.shim.remote` (port 49617), `com.apple.atc2.shim.remote` (port 49612)
- **File service:** `com.apple.coredevice.fileservice.control` (trusted only)

pymobiledevice3 documents this in [misc/RemoteXPC.md](https://github.com/doronz88/pymobiledevice3/blob/master/misc/RemoteXPC.md).

Even with RemoteXPC, the ATC shim services still require the Grappa handshake after connection establishment.

---

## 7. Alternative Approaches (Viable)

### 7A. AFC (Apple File Conduit) + iTunes Database Manipulation

**How it works:**
1. Connect to device via `com.apple.afc` lockdown service (no Grappa needed)
2. AFC provides jailed access to `/var/mobile/Media/` on the device
3. Copy video files to the appropriate media directory
4. Manipulate `iTunes_Control/iTunes/MediaLibrary.sqlitedb` to register the files

**Tools:**
- [pymobiledevice3](https://github.com/doronz88/pymobiledevice3) -- pure Python, AFC push/pull, CLI and API
- [libimobiledevice](https://libimobiledevice.org/) -- C library, ifuse for FUSE mounting
- [mountainstorm/MobileDevice](https://github.com/mountainstorm/MobileDevice) -- Python ctypes wrapper around MobileDevice.framework

**Limitations:**
- Database schema is undocumented and changes between iOS versions
- Files may not appear in TV app without correct database entries
- Artwork, metadata, media_kind flags must be set correctly
- Risk of corrupting the media database

### 7B. TV.app "Automatically Add to TV" Folder (macOS-side only)

On the Mac, TV.app monitors an "Automatically Add to TV" folder. Dropping files there imports them into the local TV library. Combined with Finder sync, this could work:

1. Drop video files into the "Automatically Add to TV" folder
2. TV.app imports them into the local library
3. Configure sync preferences to include the video content
4. Trigger a Finder sync (manually or via automation)

**Limitation:** No programmatic way to trigger step 4 (Finder sync).

### 7C. pymobiledevice3 with AFC Direct Transfer

```
# Install
pip install pymobiledevice3

# List connected devices
pymobiledevice3 usbmux list

# Push file to device media directory
pymobiledevice3 afc push local_video.mp4 /MediaLibrary/
```

AFC gives raw filesystem access to `/var/mobile/Media/` but does NOT register content with the TV/Music app database. Files land on disk but are invisible to the TV app without database manipulation.

### 7D. MobileDevice.framework via ctypes (Python)

The mountainstorm/MobileDevice project demonstrates loading Apple's private framework:
```python
from ctypes import cdll
MobileDevice = cdll.LoadLibrary(
    '/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice'
)
```

This gives access to `AMDeviceStartService()` and related C functions. However, starting `com.apple.atc` via this route still hits the Grappa authentication wall.

---

## 8. Recommended Path Forward

### Short-term: AFC + Database Reverse Engineering

1. Use pymobiledevice3 AFC to push video files to the device
2. Reverse-engineer the MediaLibrary.sqlitedb schema for the current iOS version
3. Insert proper records (media_kind, file path, metadata) so TV app recognizes them
4. Test thoroughly -- database corruption can require a full device restore

### Medium-term: Intercept Finder Sync Traffic

1. Use Wireshark/usbpcap to capture what Finder actually sends during a video sync
2. Document the exact lockdown services called and data exchanged
3. Determine if Grappa is used for `copyFiles` (drag-drop) vs full sync
4. It is possible that drag-drop file copy uses AFC rather than ATC

### Long-term: Monitor pymobiledevice3 Development

The pymobiledevice3 project is the most active open-source effort in this space. Watch for:
- ATC/Grappa protocol implementation
- RemoteXPC service documentation
- CoreDevice fileservice capabilities

---

## 9. Key Resources

- [w0lfschild/macOS_headers -- AMPDevices v15](https://github.com/w0lfschild/macOS_headers/tree/master/macOS/PrivateFrameworks/AMPDevices/15) -- class-dump headers
- [w0lfschild/macOS_headers -- AMPDevices v1.0.0](https://github.com/w0lfschild/macOS_headers/tree/master/macOS/PrivateFrameworks/AMPDevices/1.0.0) -- Catalina-era headers
- [w0lfschild/macOS_headers -- AMPLibrary](https://github.com/w0lfschild/macOS_headers/tree/master/macOS/PrivateFrameworks/AMPLibrary) -- AMPLibraryAgent headers
- [pymobiledevice3](https://github.com/doronz88/pymobiledevice3) -- pure Python iOS device interaction
- [pymobiledevice3 RemoteXPC docs](https://github.com/doronz88/pymobiledevice3/blob/master/misc/RemoteXPC.md) -- iOS 17+ protocol documentation
- [mountainstorm/MobileDevice](https://github.com/mountainstorm/MobileDevice) -- Python ctypes wrapper
- [libimobiledevice](https://libimobiledevice.org/) -- cross-platform C library
- [iPhone Wiki -- Lockdown Services.plist](https://www.theiphonewiki.com/wiki//System/Library/Lockdown/Services.plist)
- [SDMMobileDevice ATC issue](https://github.com/samdmarshall/SDMMobileDevice/issues/61) -- com.apple.atc discussion
- [George Garside -- AMPDevicesAgent explained](https://georgegarside.com/blog/macos/stop-finder-opening-when-connecting-iphone/)
- [AMPDEVICESAGENT(8) man page](https://manp.gs/mac/8/AMPDevicesAgent)
- [AMPLIBRARYAGENT(8) man page](https://keith.github.io/xcode-man-pages/AMPLibraryAgent.8.html)

---

## 10. Local Investigation Commands

These commands could not be run during this research session (sandbox restrictions) but should be executed manually to complete the picture:

```bash
# Find AMPDevicesAgent services
launchctl list | grep -i amp

# Find remoted services
launchctl list | grep -i remote

# Check framework structure
ls /System/Library/PrivateFrameworks/AMPDevices.framework/

# Symbol dump -- sync/media related
nm /System/Library/PrivateFrameworks/AMPDevices.framework/Versions/A/AMPDevices 2>/dev/null | grep -i -E "sync|atc|grappa|media|transfer" | head -40

# Symbol dump -- MobileDevice framework
nm /System/Library/PrivateFrameworks/MobileDevice.framework/Versions/A/MobileDevice 2>/dev/null | grep -i -E "sync|atc|grappa|media" | head -30

# Find related frameworks
find /System/Library/PrivateFrameworks -name "*.framework" | xargs -I{} basename {} | grep -i -E "air.?traffic|amp|mobile.?device|media.?library" 2>/dev/null

# Check running processes
ps aux | grep -i -E "amp|remoted|medialib" | grep -v grep

# Check AMPDevicesAgent entitlements
codesign -d --entitlements - /System/Library/PrivateFrameworks/AMPDevices.framework/Versions/A/Support/AMPDevicesAgent 2>&1

# Check Finder's entitlements (to see what it has for XPC)
codesign -d --entitlements - /System/Library/CoreServices/Finder.app/Contents/MacOS/Finder 2>&1

# Dump AMPDevicesAgent launchd plist
plutil -p /System/Library/LaunchAgents/com.apple.AMPDevicesAgent.plist 2>/dev/null

# Class-dump the framework yourself (if class-dump-swift is installed)
class-dump /System/Library/PrivateFrameworks/AMPDevices.framework/Versions/A/AMPDevices > ~/ampdevices_headers.h
```
