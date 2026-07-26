# Research

This directory contains the protocol research, reverse engineering documentation, and experimental scripts that were used to develop mediaporter's ATC sync implementation.

## docs/

Reverse engineering documentation for Apple's ATC (AirTrafficControl) media sync protocol:

| Document | Description |
|----------|-------------|
| [ATC_PROTOCOL.md](docs/ATC_PROTOCOL.md) | Wire format, message flow, error codes |
| [ATC_SYNC_FLOW.md](docs/ATC_SYNC_FLOW.md) | Complete 11-step sync flow with code examples |
| [IMPLEMENTATION_GUIDE.md](docs/IMPLEMENTATION_GUIDE.md) | Full implementation specification |
| [TRACE_ANALYSIS.md](docs/TRACE_ANALYSIS.md) | LLDB trace analysis of successful ATC sessions |
| [GRAPPA.md](docs/GRAPPA.md) | Grappa authentication protocol analysis |
| [IPAINSTALL_ANALYSIS.md](docs/IPAINSTALL_ANALYSIS.md) | IpaInstall (GitHub) Grappa generation analysis |
| [AIRTRAFFICHOST_FINDINGS.md](docs/AIRTRAFFICHOST_FINDINGS.md) | AirTrafficHost.framework exploration |
| [MEDIA_LIBRARY_DB.md](docs/MEDIA_LIBRARY_DB.md) | iOS MediaLibrary.sqlitedb schema |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | Module overview and data flow |
| [DEVICE_CAPABILITIES.md](docs/DEVICE_CAPABILITIES.md) | iPad lockdown values and capabilities |
| [XPC_APPROACH.md](docs/XPC_APPROACH.md) | AMPDevicesAgent XPC investigation (dead end) |
| [FINDER_AUTOMATION.md](docs/FINDER_AUTOMATION.md) | Finder automation approaches (fallback) |
| [CAPTURE_WORKFLOW.md](docs/CAPTURE_WORKFLOW.md) | LLDB trace capture methodology |
| [SUDO_FREE.md](docs/SUDO_FREE.md) | Avoiding root/sudo requirements (archived) |
| [RESEARCH_REQUEST.md](docs/RESEARCH_REQUEST.md) | Original research agenda (historical) |
| [HISTORY.md](docs/HISTORY.md) | Chronological findings log — start here for "why is it like this" |
| [ATC_PIPELINE_OPTIMIZATION.md](docs/ATC_PIPELINE_OPTIMIZATION.md) | Pipeline vs. external implementations punch-list (actioned) |
| [AMPDEVICES_AGENT_STRINGS.md](docs/AMPDEVICES_AGENT_STRINGS.md) | AMPDevicesAgent string-table decode — canonical TV-episode wire keys |
| [AUDIO_SWITCHER_RULE.md](docs/AUDIO_SWITCHER_RULE.md) | AC3→AAC + default-disposition rule for the TV.app audio switcher |
| [PHANTOM_REP_PID_TESTS.md](docs/PHANTOM_REP_PID_TESTS.md) | Phantom-row artwork experiments (closed, approach dead) |
| [RELEASE_TESTING.md](docs/RELEASE_TESTING.md) | Pre-tag unit + on-device smoke-test gates |
| [IOS_TEST_HARNESS.md](docs/IOS_TEST_HARNESS.md) | On-device iPhone verification harness (WDA + pmd3 + go-ios) |

## scripts/

Experimental PoC scripts created during protocol research. These are historical — the shipping implementation is the Swift app under `MacApp/` (the top-level `scripts/` now holds only the CIG source and the iOS test-harness driver).

### Key references
- `cig/` — CIG signature engine (compiled from go-tunes)
- `native_atc/` — Native C implementations and Grappa injection experiments
- `airtraffichost_poc*.py` — AirTrafficHost.framework exploration
- `atc_*.py` — Various ATC protocol experiments
- `xpc_*.py` — XPC approach attempts (dead end)
- `lldb_*.py` — LLDB tracing helpers

## Prior art

This research built on publicly available work:
- [yinyajiang/go-tunes](https://github.com/yinyajiang/go-tunes) — Go ATC implementation (Grappa blob, CIG engine)
- [Kerrbty/IpaInstall](https://github.com/Kerrbty/IpaInstall) — Grappa generation via fake struct (Apache 2.0)
- [libimobiledevice](https://github.com/libimobiledevice/libimobiledevice) — iOS protocol research
