# Finder / AMPDevicesAgent Capture Workflow

**Date:** 2026-04-02
**Purpose:** Capture a successful Apple-owned sync and compare it against mediaporter's ATC flow.

## Why This Comes First

We already know:

- Raw `com.apple.atc` reaches `SyncAllowed` but fails at `BeginSync`
- `AirTrafficHost.framework` connects but still fails at the FairPlay / Grappa boundary from an unsigned process
- Direct unsigned XPC to `AMPDevicesAgent` is blocked by entitlements

So the highest-signal next step is to capture a **real** sync from Finder or `AMPDevicesAgent`, then diff that traffic and call order against our own PoCs.

## Preconditions

1. Device connected and trusted
2. One fixed test asset only
3. Finder sync path confirmed to work manually
4. SIP debug restrictions relaxed if attaching to Apple processes:

```bash
csrutil enable --without debug
```

## Tools Added

- [`scripts/lldb_atc_trace.py`](/Users/faeton/Sites/mediaporter/scripts/lldb_atc_trace.py) — LLDB Python helper that logs ATC-related calls and auto-continues
- [`scripts/trace_atc_sync.sh`](/Users/faeton/Sites/mediaporter/scripts/trace_atc_sync.sh) — Wrapper that attaches LLDB to Finder or `AMPDevicesAgent`

## Recommended Capture Order

### 1. Attach to AMPDevicesAgent

Start here because it is the most likely place where Finder's high-level sync request becomes ATC traffic.

```bash
./scripts/trace_atc_sync.sh AMPDevicesAgent
```

Then trigger a manual Finder sync with a single known file.

### 2. Attach to Finder

If `AMPDevicesAgent` does not hit the expected symbols, repeat with Finder:

```bash
./scripts/trace_atc_sync.sh Finder
```

## Symbols Captured

The LLDB helper sets breakpoints on:

- `AMDeviceSecureStartService`
- `AMDServiceConnectionSend`
- `AMDServiceConnectionReceive`
- `AMDServiceConnectionSendMessage`
- `AMDServiceConnectionReceiveMessage`
- `ATHostConnectionSendHostInfo`
- `ATHostConnectionSendSyncRequest`
- `ATHostConnectionSendFileBegin`
- `ATHostConnectionSendAssetCompleted`
- `ATHostConnectionSendAssetCompletedWithMetadata`
- `ATHostConnectionSendMetadataSyncFinished`
- `ATCFMessageCreate`

The callback logs:

- raw argument registers
- Objective-C / CF object summaries when they are likely useful
- a short backtrace

## What To Look For

### Transport selection

Find the first `AMDeviceSecureStartService` hit and confirm whether Finder uses:

- `com.apple.atc`
- `com.apple.atc2`
- both in sequence

### Message construction

Check `ATCFMessageCreate` and `ATHostConnectionSend*` hits for:

- real `HostInfo`
- actual sync request options
- file begin / asset completion calls
- completion ordering

### Divergence from our PoCs

The main question is: **what call or message exists in Finder's path that does not exist in our failing path?**

## Suggested Log Review

```bash
rg -n "AMDeviceSecureStartService|ATCFMessageCreate|ATHostConnectionSend" /tmp/mediaporter-atc-trace-*.log
```

Then compare against current PoCs:

- [`scripts/atc_beginsync.py`](/Users/faeton/Sites/mediaporter/scripts/atc_beginsync.py)
- [`scripts/airtraffichost_poc4.py`](/Users/faeton/Sites/mediaporter/scripts/airtraffichost_poc4.py)

## Success Criteria

We should not call the capture successful unless it gives us at least one of these:

1. The exact service name Finder uses for the successful path
2. A `HostInfo` or sync request shape we are currently missing
3. A file / asset completion call sequence we can reproduce
4. A clear proof that Finder relies on a path our process cannot use without entitlements

## Notes

- [`scripts/capture_sync.sh`](/Users/faeton/Sites/mediaporter/scripts/capture_sync.sh) is still only useful for older usbmuxd-visible traffic. It is **not** the preferred capture path on iOS 17+ because Finder uses RemoteXPC-backed transport.
