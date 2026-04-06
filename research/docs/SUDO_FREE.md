# Sudo-Free Tunnel Research

## Findings

### macOS Services Running

```
remoted (PID 375) — runs as root, manages device tunnels for Xcode/Finder
AMPDevicesAgent (PID 72499) — runs as USER (faeton), handles media sync
AMPLibraryAgent (PID 29029) — runs as USER, manages music library
AMPDeviceDiscoveryAgent (PID 730) — runs as USER, discovers devices
AMPArtworkAgent (PID 29030) — runs as USER, fetches artwork
```

### Key Finding: AMPDevicesAgent runs as USER, not root

AMPDevicesAgent is the process that handles media sync (confirmed by `airtraffic>` log strings in binary). It runs under the current user account, not root. This means **it connects to the device without needing its own sudo tunnel** — it likely uses `remoted` (which runs as root) to proxy the connection.

### pymobiledevice3 Tunnel Options

Both tunnel commands require sudo:
- `pymobiledevice3 remote start-tunnel` — creates utun interface (needs root)
- `pymobiledevice3 lockdown start-tunnel` — also requires root

### Potential Solutions

1. **Reuse remoted's tunnel** — If we can discover the RSD address/port that remoted uses, we could connect via `--rsd HOST PORT` without creating our own tunnel.

2. **tunneld as LaunchDaemon** — Run pymobiledevice3 tunneld once at boot. All subsequent connections use it without sudo:
   ```bash
   sudo pymobiledevice3 remote tunneld -d  # daemonize, runs in background
   # Then: mediaporter devices  # no sudo needed for actual commands
   ```
   This is already how our current setup works — tunneld runs, mediaporter connects through it.

3. **XPC to AMPDevicesAgent** — If we can call AMPDevicesAgent's XPC interface, it handles the device connection internally using remoted. No tunnel needed from our side at all.

## Current Status

The tunneld approach already works (sudo needed once to start the daemon). The XPC approach (Move 1 in RESEARCH_REQUEST.md) could eliminate sudo entirely.
