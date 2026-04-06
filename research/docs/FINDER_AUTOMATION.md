# Finder Sync Automation Research

**Date:** 2026-04-01
**Purpose:** Evaluate all approaches for programmatically triggering media sync to iPad's TV app, as a fallback to implementing Grappa auth for the ATC protocol.

> **NOTE (2026-04-06):** This fallback is NO LONGER NEEDED. The ATC protocol is fully working with Grappa replay. See `CLAUDE.md` and `scripts/atc_proper_sync.py`.

## Context

Finder can sync videos to iPad's TV app correctly (confirmed working). The ATC protocol conversation gets to `SyncAllowed` but `BeginSync` fails with ErrorCode 12 (Grappa auth missing). If we can automate what Finder does, we have a working solution without implementing Grappa ourselves.

---

## Approach 1: AppleScript / osascript — Direct Finder Scripting

**Verdict: NOT VIABLE for direct sync commands**

Finder's AppleScript dictionary does NOT expose device sync as a scriptable command. There is no `tell application "Finder" to sync device` or similar verb. Finder is scriptable for file/folder operations (move, copy, duplicate, make new folder, etc.) but the device sync panel is a custom UI that is not part of the AppleScript object model.

Confirmed: the Finder scripting dictionary (viewable via Script Editor > Open Dictionary > Finder) contains no commands related to iOS device management, media sync, or device sidebar items.

### What AppleScript CAN do with Finder:
- File/folder manipulation (copy, move, delete, reveal)
- Window management (open, close, resize, set sidebar width)
- Get/set Finder preferences
- Open files with specific applications

### What it CANNOT do:
- Select a device in the sidebar programmatically
- Navigate to the Movies sync tab
- Add files to the sync queue
- Trigger sync/apply

---

## Approach 2: AppleScript UI Scripting (System Events)

**Verdict: VIABLE but FRAGILE — best available fallback**

UI scripting via System Events can simulate clicks on any visible UI element. This could automate the entire Finder sync workflow by clicking through the UI.

### How it would work:
```applescript
tell application "System Events"
    tell process "Finder"
        -- Click device in sidebar
        -- Click "Movies" tab
        -- Check "Sync movies" checkbox
        -- Select specific movie files
        -- Click "Apply" / "Sync" button
    end tell
end tell
```

### Requirements:
1. **Accessibility permissions** — must be granted manually in System Preferences > Privacy & Security > Accessibility for the script/app
2. **Finder must be open** with the device visible in the sidebar
3. **Device must be connected** via USB
4. **Accessibility Inspector** (from Xcode) needed to discover exact UI element names and hierarchy

### Pros:
- Actually triggers real Finder sync (Grappa handled by Finder/AMPDevicesAgent)
- No reverse engineering required
- Videos appear correctly in TV app (confirmed)

### Cons:
- Extremely fragile — UI element names change between macOS versions
- Finder window must be visible and in specific state
- Slow (UI animation delays)
- Requires manual Accessibility permission grant
- Cannot run headless / in background
- Different locales have different button names

### Implementation approach:
1. Use Accessibility Inspector to map out the exact UI hierarchy of Finder's device sync panel
2. Write osascript that navigates: Sidebar device > Movies tab > Sync checkbox > file selection > Apply
3. Add explicit waits between UI actions
4. Handle errors when elements are not found

---

## Approach 3: Apple Configurator CLI (cfgutil)

**Verdict: NOT VIABLE for media sync**

cfgutil is Apple Configurator's command-line tool, installed to `/usr/local/bin/cfgutil`. It is designed for enterprise device management (MDM enrollment, app deployment, restore, backup).

### Complete list of cfgutil verbs:
- `activate` — Activate devices
- `add-tags` — Tag devices
- `backup` — Create device backup
- `clear-passcode` — Clear passcode (supervised only)
- `erase` — Erase content and settings (supervised only)
- `exec` — Run scripts on device connect/detach
- `get` — Show device properties
- `get-app-icon` — Copy app icon
- `get-icon-layout` — Get home screen layout
- `get-unlock-token` — Get unlock token (supervised only)
- `help` — Show help
- `install-app` — Install .ipa files
- `install-doc` — Push documents to app sandboxes
- `install-profile` — Install configuration profiles
- `list` — List attached devices
- `list-backups` — List local backups
- `pair` — Pair with device
- `prepare` — Run prepare workflow
- `remove-app` — Remove app by bundle ID
- `remove-profile` — Remove profile
- `restore-backup` — Restore from backup
- `set-wallpaper` — Set wallpaper (supervised only)
- `shut-down` — Power off device (supervised only)
- `syslog` — Stream device syslog
- `unpair` — Remove pairing
- `version` — Show version

### Key finding:
There is NO `install-media`, `add-media`, `add-video`, `sync-content`, or any media-related command. cfgutil is strictly for device provisioning, not media sync.

`install-doc` pushes documents to app sandboxes (like iTunes file sharing), but this is NOT the same as adding media to the TV app library. It would only put files into an app's Documents folder, not register them in the media database.

### Status on this system:
cfgutil requires Apple Configurator to be installed. Needs manual verification: run `cfgutil help` or check if `/usr/local/bin/cfgutil` exists.

---

## Approach 4: AMPDevicesAgent XPC Interface

**Verdict: MOST PROMISING unexplored path**

AMPDevicesAgent is the macOS daemon that Finder delegates all device sync operations to. It:
- Handles protocol-level conversations with iOS devices over USB
- Negotiates pairing
- Manages the ATC protocol including Grappa authentication
- Is part of Apple Mobile Platform (AMP) framework built into macOS

### Key insight:
Finder does NOT talk ATC directly. It sends XPC messages to AMPDevicesAgent, which handles Grappa auth and ATC internally. If we can send the same XPC messages, AMPDevicesAgent handles all the hard parts.

### XPC service location:
`/System/Library/PrivateFrameworks/AMPDevices.framework/Versions/A/Support/AMPDevicesAgent`

### Challenges:
- XPC interface is undocumented (private API)
- May require specific entitlements (`com.apple.private.amp.devices`)
- Need to reverse-engineer the XPC message format
- SIP (System Integrity Protection) may block interception

### Investigation steps needed:
1. Use `launchctl list | grep AMP` to find the service identifier
2. Use Frida or LLDB to hook AMPDevicesAgent during a Finder sync to capture XPC messages
3. Examine the XPC message structure (likely NSXPCConnection with defined protocol)
4. Try sending equivalent XPC messages from our own process
5. Check if entitlements block unsigned code from connecting

---

## Approach 5: MobileDevice.framework (Private)

**Verdict: PARTIALLY VIABLE — file transfer yes, TV app registration no**

MobileDevice.framework is the private macOS framework for iOS device communication, located at:
`/System/Library/PrivateFrameworks/MobileDevice.framework/`

### What it provides:
- `AMDeviceConnect` / `AMDeviceStartSession` — Device connection
- `AMDeviceStartService` — Start lockdown services
- `AMDeviceCopyValue` — Read device properties
- AFC file access via `com.apple.afc`
- House Arrest service for app sandbox access

### Limitations:
- Private/undocumented API (no Apple documentation)
- Does NOT expose ATC sync or Grappa auth directly
- AFC can push files to `/var/mobile/Media/` but cannot register them in the TV app database
- We already have this via pymobiledevice3 (which reimplements the protocol)

### Existing tools using MobileDevice.framework:
- **SDMMobileDevice** (github.com/samdmarshall/SDMMobileDevice) — Open reimplementation
- **mobiledevice** (github.com/imkira/mobiledevice) — CLI wrapper
- **pymobiledevice3** — Pure Python reimplementation (already in our stack)

---

## Approach 6: pymobiledevice3 AFC Media Sync

**Verdict: FILE TRANSFER WORKS, TV APP REGISTRATION DOES NOT**

We already use pymobiledevice3 for AFC file transfer. The problem is well-understood:
- AFC can push files to `iTunes_Control/Music/Fxx/`
- But without ATC protocol (which requires Grappa), the TV app's medialibraryd never learns about the files
- Direct MediaLibrary.sqlitedb modification does NOT work (reverted by daemon)

pymobiledevice3 features relevant to our problem:
- AFC file access (already working)
- Lockdown service access (already using for ATC)
- RemoteXPC support (iOS 17+ tunnels)
- Device pairing

It does NOT implement ATC sync or Grappa auth.

---

## Approach 7: iTunesLibrary.framework (macOS)

**Verdict: NOT VIABLE — read-only**

iTunesLibrary.framework is a PUBLIC macOS framework, but it is READ-ONLY. It provides access to the user's music/video library on the Mac (Music.app / TV.app library).

- `ITLibrary` — Entry point, read library contents
- `ITLibMediaItem` — Individual media items
- PyObjC provides Python bindings (`import iTunesLibrary`)

### Key limitation:
This framework reads the LOCAL macOS library. It does NOT interact with connected iOS devices in any way. It cannot trigger sync, add items to sync queue, or communicate with devices.

### Requirement:
Application must be code-signed to get usable data from the framework.

---

## Approach 8: MPMediaLibrary / MusicKit (iOS-side)

**Verdict: NOT VIABLE — Apple Music only**

`MPMediaLibrary.addItem(withProductID:)` can add items to the iOS music library, BUT:
- Only works with Apple Music catalog tracks (requires Apple Music subscription)
- Cannot add arbitrary local video files
- Requires the app to run ON the iOS device
- Does not support video content for the TV app

MusicKit is similarly limited to Apple Music catalog content.

---

## Approach 9: MDM / Device Management

**Verdict: NOT VIABLE — enterprise only, no media sync**

MDM (Mobile Device Management) solutions can:
- Install apps
- Push configuration profiles
- Manage device settings
- Distribute apps from Apple Business/School Manager

MDM CANNOT:
- Push arbitrary video files to the TV app
- Trigger media sync
- Add content to the device media library

MDM is designed for enterprise device management, not media content delivery.

---

## Approach 10: libimobiledevice / ifuse

**Verdict: SAME LIMITATION AS pymobiledevice3**

libimobiledevice provides:
- AFC file access (same as pymobiledevice3)
- House Arrest (app sandbox file access)
- Backup/restore
- Installation proxy (app install)

It does NOT implement:
- ATC protocol
- Grappa authentication
- Media library registration

ifuse can mount the device filesystem via FUSE, but writing files to `iTunes_Control/Music/` via mount has the same problem — files exist but are not registered in the TV app.

---

## Approach 11: Automator Workflows

**Verdict: LIMITED — same constraints as AppleScript**

Automator can chain AppleScript actions and shell scripts, but for device sync it has the same limitations:
- No native "sync device" action
- Would need to wrap UI scripting (System Events) approach
- Same fragility as Approach 2

---

## Approach 12: macOS Shortcuts

**Verdict: NOT VIABLE**

macOS Shortcuts (introduced in macOS Monterey) does not include any actions for:
- iOS device communication
- Media sync
- Device file transfer
- ATC protocol

Shortcuts are designed for on-device automation and cross-app workflows, not device management.

---

## Approach 13: PhotosMigrator (iOS App)

**Verdict: NOT APPLICABLE — Photos only, requires iOS app**

PhotosMigrator (github.com/VaslD/PhotosMigrator) is an iOS app that imports photos/videos from the Files app into the Camera Roll. It:
- Requires running ON the iOS device
- Imports to Photos app, NOT TV app
- Is archived/unmaintained (March 2022)
- Uses iOS Photos framework (PHAsset), not applicable to TV app

---

## Summary & Recommendations

### Tier 1: Most Promising

| Approach | Viability | Effort | Reliability |
|----------|-----------|--------|-------------|
| **UI Scripting (Approach 2)** | Works now | Medium | Fragile |
| **AMPDevicesAgent XPC (Approach 4)** | Needs research | High | Potentially solid |

### Tier 2: Worth Investigating

| Approach | Viability | Notes |
|----------|-----------|-------|
| **Frida hook on AMPDevicesAgent** | Could capture Grappa | Helps solve ATC directly |

### Tier 3: Dead Ends

| Approach | Why |
|----------|-----|
| AppleScript direct Finder scripting | No sync commands in dictionary |
| cfgutil / Apple Configurator | No media sync verbs |
| iTunesLibrary.framework | Read-only, macOS local library only |
| MPMediaLibrary / MusicKit | Apple Music catalog only |
| MDM | Enterprise only, no media content |
| libimobiledevice / AFC alone | File transfer only, no DB registration |
| macOS Shortcuts | No device management actions |

### Recommended Next Steps

1. **Immediate fallback: UI Scripting**
   - Use Accessibility Inspector to map Finder's device sync panel
   - Write an osascript that automates: open device > Movies tab > add video > Apply
   - Accept fragility as trade-off for working solution
   - Test on current macOS version, document UI element hierarchy

2. **Parallel investigation: AMPDevicesAgent XPC**
   - Attach Frida to AMPDevicesAgent during a manual Finder sync
   - Capture XPC messages being sent from Finder to AMPDevicesAgent
   - Determine if we can replay these messages from our own process
   - This could yield a clean, non-fragile automation path

3. **Continue ATC/Grappa research**
   - Hooking AMPDevicesAgent with Frida may also reveal the Grappa handshake in cleartext
   - This would solve the root problem (ATC ErrorCode 12) directly
   - See `docs/ATC_PROTOCOL.md` Next Steps section

---

## Key Sources

- [Apple: Sync movies between Mac and device](https://support.apple.com/guide/mac-help/mchl36119991/mac)
- [Apple: Automating the User Interface (AppleScript)](https://developer.apple.com/library/archive/documentation/LanguagesUtilities/Conceptual/MacAutomationScriptingGuide/AutomatetheUserInterface.html)
- [Apple: iTunesLibrary framework](https://developer.apple.com/documentation/ituneslibrary)
- [Apple: MPMediaLibrary](https://developer.apple.com/documentation/mediaplayer/mpmedialibrary)
- [Apple: Install cfgutil](https://support.apple.com/guide/apple-configurator-mac/use-the-command-line-tool-cad856a8ea58/mac)
- [cfgutil verbs (krypted)](https://krypted.com/apple-configurator/apple-configurator-cfgutil-verbs/)
- [cfgutil man page (GitHub Gist)](https://gist.github.com/JuryA/46d503aec17da6fb54837fead798e3b2)
- [MobileDevice Library (Apple Wiki)](https://theapplewiki.com/wiki/MobileDevice_Library)
- [AFC protocol (Apple Wiki)](https://theapplewiki.com/wiki/AFC)
- [SDMMobileDevice](https://github.com/samdmarshall/SDMMobileDevice)
- [pymobiledevice3](https://github.com/doronz88/pymobiledevice3)
- [libimobiledevice](https://libimobiledevice.org/)
- [PhotosMigrator](https://github.com/VaslD/PhotosMigrator)
- [AMPDevicesAgent explained (George Garside)](https://georgegarside.com/blog/macos/stop-finder-opening-when-connecting-iphone/)
- [PyObjC iTunesLibrary bindings](https://pyobjc.readthedocs.io/en/latest/apinotes/iTunesLibrary.html)
- [iMore: Transfer ripped videos to iPad](https://www.imore.com/how-transfer-ripped-videos-your-iphone-or-ipad-your-mac)
