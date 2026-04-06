# mediaporter — Research Request (HISTORICAL)

> **NOTE (2026-04-06):** This research request is HISTORICAL. The ATC sync blocker has been fully resolved. Videos now sync to the TV app with correct metadata (media_type=2048, media_kind=2). See `CLAUDE.md` "Confirmed Findings (2026-04-06)" and `scripts/atc_proper_sync.py` for the working solution.

## Context

We're building an open-source CLI tool (`mediaporter`) that transfers video files to iOS devices over USB-C and makes them appear in the **native Apple TV app**. The transcoding pipeline is complete. The blocker was the last mile: making the file appear in the TV app.

**Project location:** `/Users/faeton/Sites/mediaporter/`
**Docs with all findings:** `docs/ATC_PROTOCOL.md`, `docs/MEDIA_LIBRARY_DB.md`, `docs/ARCHITECTURE.md`
**CLAUDE.md** has critical learnings and design priorities.

## What We Knew (at time of writing)

1. The `com.apple.atc` (AirTrafficControl) lockdown service is the **only** way to properly sync media to the iOS TV app. Direct modification of `MediaLibrary.sqlitedb` gets reverted by `medialibraryd` within seconds.

2. We can connect to ATC and have a conversation:
   - Device sends `Capabilities` (Grappa v1, protocolVersion 1)
   - We respond with `Capabilities`
   - Device sends `InstalledAssets`, `AssetMetrics` (shows 11 movies, 7 TV eps)
   - We send `RequestingSync` → device responds `SyncAllowed`
   - We send `BeginSync` → device responds **`SyncFailed` ErrorCode 12, RequiredVersion "10.5.0.115"**

3. The wire format is: **4-byte little-endian length + binary plist**.

4. A Finder sync creates valid entries with `media_type=8192`, `media_kind=1024`, and a 57-byte `integrity` blob that's a Grappa-signed hash.

5. iOS 17+ uses RemoteXPC tunnels — socat usbmuxd proxy does NOT capture ATC traffic.

6. `pymobiledevice3` requires `sudo` for the tunnel.

## Research Moves Explored

### Move 1: AMPDevicesAgent XPC Interface → BLOCKED (entitlements)
### Move 2: LLDB Trace on AMPDevicesAgent/Finder → SUCCESS (led to full protocol capture)
### Move 3: com.apple.atc2 Protocol → Dead end (no initial message)
### Move 4: Grappa Reverse Engineering → RESOLVED via replay of static blob from go-tunes
### Move 5: macOS `remoted` Daemon → Not needed (MobileDevice.framework works without sudo)
### Move 6: Apple Configurator / cfgutil → Dead end (no media sync commands)
### Move 7: Finder Automation → Not needed (direct ATC works)
### Move 8: Avoiding sudo/root → Partially solved (MobileDevice.framework, but tunnel still needs sudo)
### Move 9: MobileDevice.framework Direct Use → SUCCESS (core of working solution)
### Move 10: Community Outreach → Not needed

## Resolution

The full ATC sync protocol was reverse-engineered through LLDB tracing of Finder/AMPDevicesAgent, combined with the open-source `yinyajiang/go-tunes` project (Grappa blob, CIG engine). See `docs/ATC_SYNC_FLOW.md` and `docs/IMPLEMENTATION_GUIDE.md` for the complete working solution.
