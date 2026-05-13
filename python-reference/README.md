# mediaporter — Python reference

Historical Python implementation of the ATC sync pipeline. **This is not the shipping target** — the active app is the Swift MacApp in `../MacApp/`. This code is kept for protocol-level reference and is no longer maintained in lockstep.

## Why it exists

The Python implementation proved the ATC protocol end-to-end and produced the trace evidence the Swift port was built from. It still works against current iOS, but new features land in Swift first and the Python CLI lags behind.

If you're reading the codebase to understand the protocol — start here. The modules map cleanly to wire-level concepts:

- `src/mediaporter/sync/atc.py` — ATC handshake, replayable Grappa, message framing
- `src/mediaporter/sync/__init__.py` — full sync orchestration
- `src/mediaporter/pipeline.py` — transcode/upload/register pipeline
- `src/mediaporter/transcode.py` — ffmpeg wrapper, codec decisions
- `src/mediaporter/metadata.py` — TMDb lookup, MP4 atom writing
- `src/mediaporter/probe.py` — ffprobe wrapper, compatibility checks

The shared `traces/grappa.bin` and `../scripts/cig/` artifacts are used by both implementations.

## Differences from the Swift app

- **Tunnel:** the Python path reimplements the iOS 17+ RemoteXPC tunnel via `pymobiledevice3`, which requires `sudo pymobiledevice3 remote start-tunnel` once per boot to create the userspace `utun` interface. The Swift app sidesteps this entirely by `dlopen`-ing Apple's own `MobileDevice.framework`, which talks to the system `remoted`/`usbmuxd` daemons — no sudo needed.
- **Distribution:** Python is `pip install -e .` only. Swift ships signed, notarized, and downloadable from porter.md.
- **Feature parity:** the Swift app has features the Python CLI does not (drag-and-drop, OpenSubtitles fetch, device cleanup menu, mid-sync disk polling). The CLI parity story will be revisited later.

## Dev setup

```bash
cd python-reference
python -m venv .venv
source .venv/bin/activate
pip install -e ".[dev]"
mediaporter devices
```

Python 3.11+. `brew install ffmpeg` separately. Tunnel: `sudo pymobiledevice3 remote start-tunnel` once per boot.

## Scripts

- `scripts/atc_nodeps_sync.py` — zero-dependency proof of working sync via `ctypes` + Apple frameworks
- `scripts/atc_proper_sync.py` — full sync via the package
- `scripts/atc_tv_series_test.py` — TV-episode metadata test path
- `scripts/lldb_atc_trace.py` — protocol trace harness
- `scripts/trace_atc_sync.sh` — driver wrapper

## See also

- `../research/docs/` — protocol research, including `HISTORY.md` (chronological findings) and `ATC_SYNC_FLOW.md` (wire-level reference)
- `../MacApp/` — the shipping Swift app
- `../CLAUDE.md` — top-level project rules (critical protocol facts apply to both implementations)
