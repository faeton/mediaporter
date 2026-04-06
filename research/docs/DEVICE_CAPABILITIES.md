# iPad Device Capabilities (com.apple.mobile.iTunes domain)

Dumped from iPad8,7, iOS 26.3.1, UDID 00008027-000641441444002E on 2026-04-01.

## Key Values for Media Sync

| Key | Value | Relevance |
|-----|-------|-----------|
| `DBVersion` | 5 | ATC-era database format (not older iTunesDB) |
| `SupportsAirTraffic` | True | Device supports ATC protocol |
| `HomeVideosSupported` | True | Supports "Home Video" media type |
| `FairPlayDeviceType` | 200 | FairPlay DRM type |
| `FairPlayGUID` | `00008027-000641441444002E` | Same as device UDID |
| `FairPlayCertificate` | (binary blob) | DER-encoded X.509 cert |
| `FairPlayCBMaxVersion` | 4 | FairPlay callback version range |
| `MinITunesVersion` | `12.9.0` | Minimum iTunes version required |
| `MinMacOSVersion` | `10.5.8` | Minimum macOS required |
| `ConnectedBus` | `USB` | Connection type |

## Grappa ↔ FairPlay Connection

The presence of `FairPlayCertificate`, `FairPlayDeviceType`, and `FairPlayGUID` alongside `SupportsAirTraffic` suggests Grappa authentication may be built on top of FairPlay infrastructure. The FairPlay certificate could be used in the Grappa session establishment.

## Supported Media Types

| Type | Supported |
|------|-----------|
| Home Videos | Yes |
| Rentals | Yes |
| TV Show Rentals | Yes |
| Customer Ringtones | Yes |
| Podcasts | Yes |
| Voice Memos | Yes |
| Genius Mixes | Yes |
| Video Playlists | Yes |
| Playlist Folders | Yes |
| Photo Events/Faces/Videos | Yes |

## Video Codecs

The `VideoCodecs` dict includes: AppleProRes422, H264, MPEG4 with AAC audio support.

## Sync Data Classes

Lockdown-advertised sync classes: `Contacts`, `Calendars`, `Bookmarks`, `Mail Accounts`, `Notes`

Note: Media sync is NOT in this list — it goes through ATC, not mobilesync.

## AMPDevicesAgent XPC Services

Found in the AMPDevicesAgent binary:

| Service | Purpose |
|---------|---------|
| `com.apple.amp.devices` | Main devices XPC service |
| `com.apple.amp.devices.client` | Client interface |
| `com.apple.amp.devices.client.ui` | UI client interface |
| `com.apple.amp.devicesd` | Device daemon |
| `com.apple.amp.library` | Library management |
| `com.apple.amp.library.devicecontents` | **Device content management** |
| `com.apple.configurationutility.xpc.DeviceService` | Configurator integration |

## Sync Control Notifications

| Notification | Direction |
|-------------|-----------|
| `com.apple.itunes-mobdev.syncWillStart` | Host → Device |
| `com.apple.itunes-mobdev.syncDidStart` | Host → Device |
| `com.apple.itunes-mobdev.syncDidFinish` | Host → Device |
| `com.apple.itunes-mobdev.syncFailedToStart` | Device → Host |
| `com.apple.itunes-mobdev.syncLockRequest` | Host → Device |
| `com.apple.itunes-client.syncCancelRequest` | Client → Agent |
| `com.apple.itunes-client.syncResumeRequest` | Client → Agent |
| `com.apple.itunes-client.syncSuspendRequest` | Client → Agent |

## AirTraffic Log Strings in AMPDevicesAgent

The binary contains detailed logging that reveals the sync protocol:
- `airtraffic> sending RequestingSync for device %@, dataclasses = %@, anchors = %@`
- `airtraffic> sending FinishedSyncingMetadata for device %@, syncTypes = %@, anchors = %@, purgeDataBytes = %llu, freeDiskBytes = %llu`
- `airtraffic> sending FileComplete for device %@, asset identifier "%@", dataclass %@ (%u), path "%@", new sync anchor %@`
- `kTrackDataAddFileNeverSyncFileLocationOption | kTrackDataAddFileAllowDuplicatesOption`
