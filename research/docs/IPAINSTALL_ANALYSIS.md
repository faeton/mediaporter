# IpaInstall Repository Analysis (Kerrbty/IpaInstall)

Analysis of https://github.com/Kerrbty/IpaInstall — a Windows-based tool (Apache 2.0 license) that performs Apple ID authorization on iOS devices and installs IPA files, using iTunes DLLs for Grappa generation and AirFairSync operations.

## Repository Architecture

The project has a **client-server architecture**:
- **Server** (`server/iOSAuthRuntime/`): Runs on a Windows machine with iTunes 12.4.3.1 (32-bit). Loads iTunes DLLs, generates Grappa blobs, creates AirFairSync sessions, and computes authorization responses.
- **Client** (`client/aid2/`): Runs on a Windows machine with iTunes 12.12+ (64-bit). Connects to iOS device, extracts FairPlay info, manages the ATC sync flow, and communicates with the server for crypto operations.

**Key insight**: The server and client are separate because the crypto operations (Grappa, AirFairSync) require calling internal functions from iTunes DLLs at hardcoded offsets. The client handles device communication; the server handles the crypto that requires iTunes internals.

## Important Caveat: This is About DRM Authorization, NOT Video Transfer

**This repository is about authorizing Apple IDs on devices (for installing purchased apps without the original Apple ID), NOT about transferring video files to the TV app.** The ATC/Grappa flow here is used for DRM authorization, not media sync. However, the Grappa generation mechanism is the same one needed for media sync.

---

## 1. How AirFairSyncGrappaCreate is Called

### The Fake ATHostConnection Struct

The critical discovery is in `Handle.cpp` — `AirFairSyncGrappaCreate()`. The actual function in `AirTrafficHost.dll` expects an `ATHostConnection` internal struct pointer, but IpaInstall constructs a **fake 512-byte struct** and passes specific fields from it:

```cpp
NTSTATUS AirFairSyncGrappaCreate(const char* _UDID, void** _GPA_Data, DWORD* _GPA_Size, AUTH_GRAPPA* _Grappa)
{
    // The REAL function signature in AirTrafficHost.dll:
    // int func(uint32_t* _Unknown1, uint32_t* _Unknown2, void** _GPA_Data, DWORD* _GPA_Size)

    char* vATH_Connect = new char[512];
    memset(vATH_Connect, 0, 512);

    // On x64:
    // Offset 0:  uint64 = 0   (vArg_0)
    // Offset 8:  uint64 = 0   (vArg_1)
    // Offset 16: uint32 = 2   (vArg_2)
    // Offset 20: uint32 = 1   (vArg_3)
    // Offset 24: uint32 = 1   (vArg_4) ← passed as 1st arg
    // Offset 28: uint32 = 0   (vArg_5)
    // Offset 32: uint32 = 1   (vArg_6)
    // Offset 36: uint32 = 0   (vArg_7) ← passed as 2nd arg, receives Grappa handle
    // Offset 40: char[] = UDID string (vArg_8)

    *vArg_0 = 0;
    *vArg_1 = 0;
    *vArg_2 = 2;
    *vArg_3 = 1;
    *vArg_4 = 1;   // passed to function as arg1
    *vArg_5 = 0;
    *vArg_6 = 1;
    *vArg_7 = 0;   // passed to function as arg2, output: Grappa session handle
    strcpy(vArg_8, _UDID);

    int vStatus = vFuncEntry(vArg_4, vArg_7, _GPA_Data, _GPA_Size);
    *_Grappa = (AUTH_GRAPPA)*vArg_7;
    return vStatus;
}
```

**Key values in the fake struct**:
- `vArg_2 = 2` — Possibly a protocol version or connection type
- `vArg_3 = 1` — Unknown flag
- `vArg_4 = 1` — Passed as first argument, possibly "enable Grappa" flag
- `vArg_6 = 1` — Unknown flag
- `vArg_8` = UDID string — Device identifier
- `vArg_7` = Output — Receives the Grappa session handle

**The actual call**: `AirFairSyncGrappaCreate(ptr_to_vArg4, ptr_to_vArg7, &out_data, &out_size)` returns:
- `_GPA_Data` / `_GPA_Size`: The Grappa blob data to send to the device
- `_Grappa` (from vArg_7): A session handle for subsequent `AirFairSyncGrappaUpdate` and `AirFairSyncCalcSig` calls

### Function Offsets (for reference)

All functions are called at hardcoded offsets from DLL base addresses:

| Function | DLL | Offset (x64, 12.13.0.9) |
|---|---|---|
| KBSyncMachineId | iTunesCore.dll | 0x00825C30 |
| KBSyncLibraryId | iTunesCore.dll | 0x00826080 |
| KBSyncCreateToken | iTunesCore.dll | 0x0001E650 |
| AirFairSyncSessionCreate | iTunesCore.dll | 0x000316B0 |
| AirFairSyncGrappaCreate | AirTrafficHost.dll | 0x00011110 |
| AirFairSyncGrappaUpdate | AirTrafficHost.dll | 0x00003430 |
| AirFairSyncVerifyRequest | iTunesCore.dll | 0x00088F10 |
| AirFairSyncSetRequest | iTunesCore.dll | 0x000191C0 |
| AirFairSyncAccountAuthorize | iTunesCore.dll | 0x000589D0 |
| AirFairSyncGetResponse | iTunesCore.dll | 0x00084F60 |
| AirFairSyncCalcSig | iTunesCore.dll | 0x00020A40 |

---

## 2. KBSync Keys and Token Creation

### KBSyncMachineKey
Calls an internal iTunesCore function to get the 20-byte machine key.

### KBSyncLibraryKey
Same pattern — gets the 20-byte library key from iTunesCore.

### KBSyncDeviceKey
**Does NOT call iTunes functions** — constructs the key from the UDID directly:
- For 40-char UDIDs (old format): Hex-decode the UDID string to 20 bytes
- For 25-char UDIDs (new format, e.g., `00008110-001544A01E38801E`): Constructs a 20-byte key with magic prefix `0xB0A49760 0x9F0A0AC2` + hex-decoded parts of the UDID

### KBSyncTokenCreate
```
KBSyncTokenCreate(MachineKey, LibraryKey, "C:\\ProgramData\\Apple Computer\\iTunes\\SC Info", &Token)
```
Creates a token from machine key + library key + SC Info directory (contains FairPlay signing data).

### Type Definitions
```c
typedef struct { uint32_t size; uint8_t data[38]; } AUTH_KEY;  // 20 bytes used
typedef void* AUTH_TOKEN;
typedef void* AUTH_SESSION;
typedef void* AUTH_GRAPPA;   // Grappa session handle
typedef ULARGE_INTEGER AUTH_DSID;  // Apple ID identifier
typedef struct { uint32_t deviceType; uint32_t keyTypeSupportVersion; } AUTH_ATTR;
```

---

## 3. Complete Authorization Flow (Server + Client)

### Phase 1: Device Info Collection (Client)

1. Client connects to iOS device via USB (MobileDevice framework)
2. Pairs with device (`AMDeviceValidatePairing` / `AMDevicePair`)
3. Reads from `com.apple.mobile.iTunes` domain:
   - `FairPlayCertificate` — binary blob (variable length)
   - `FairPlayDeviceType` — uint32
   - `KeyTypeSupportVersion` — uint32 (packed into upper 32 bits of FairPlayDeviceType)
4. Gets device UDID
5. Sends to server: `{uid_len, fpc_len, GrappaSupportInfo[5], FairPlayArgs[4], UDID, FairPlayCertificate}`

### Phase 2: Grappa Generation (Server)

1. Server receives package 1
2. `KBSyncMachineKey()` → machine key
3. `KBSyncLibraryKey()` → library key
4. `KBSyncTokenCreate(machine, library, SCInfoDir)` → token
5. `KBSyncDeviceKey(UDID)` → device key (from UDID directly)
6. `AirFairSyncSessionCreate(token, FairPlayCert, FairPlayCertLen, deviceKey, {deviceType, keyTypeSupportVersion}, 7, &session)` → session
7. `AirFairSyncGrappaCreate(UDID, &grappaData, &grappaSize, &grappaHandle)` → Grappa blob
8. Server sends Grappa blob back to client

### Phase 3: ATC Sync (Client)

1. `ATHostConnectionCreateWithLibrary("5AC547BA5322B210", UDID, 0)` — creates ATH connection
2. Read messages in loop until `SyncAllowed` received
3. Send `RequestingSync` message with Grappa blob embedded:
   ```
   RequestingSync.Params = {
     Dataclasses: ["Keybag"],
     DataclassAnchors: {},
     HostInfo: {
       Version: "12.6.0.100",
       SyncedDataclasses: [],
       SyncHostName: "pc",
       LibraryID: "5AC547BA5322B210",
       Grappa: <binary blob from server>
     }
   }
   ```
4. Read messages until `ReadyForSync` — extract `Params.DeviceInfo.Grappa` (device's Grappa response)

### Phase 4: AirFairSync Authorization (Server)

1. Client sends to server: `{device_grappa(0x53 bytes), afsync.rq.sig(0x15 bytes), afsync.rq(variable)}`
   - `afsync.rq` and `afsync.rq.sig` are read from device via AFC at `/AirFair/sync/afsync.rq` and `/AirFair/sync/afsync.rq.sig`
2. Server calls:
   - `AirFairSyncSetRequest(session, rqData, rqSize, 0, 0)` — sets the request
   - `AirFairSyncAccountAuthorize(session, DSID, 0, 0)` — authorizes with Apple ID's DSID
   - `AirFairSyncGrappaUpdate(grappaHandle, deviceGrappa, deviceGrappaSize)` — updates Grappa with device's response
   - `AirFairSyncGetResponse(session, &rsData, &rsSize, &unk1, &unk2)` — gets authorization response
   - `AirFairSyncCalcSig(grappaHandle, rsData, rsSize, &sigData, &sigSize)` — calculates signature
3. Server sends back: `{afsync.rs.sig(0x15 bytes) + afsync.rs(variable)}`

### Phase 5: Write Back & Finish (Client)

1. Client writes `afsync.rs` and `afsync.rs.sig` to device via AFC at `/AirFair/sync/afsync.rs` and `/AirFair/sync/afsync.rs.sig`
2. `ATHostConnectionSendMetadataSyncFinished(ath, {Keybag: 1}, {})` — signal metadata done
3. Read messages until `SyncFinished` (or `SyncFailed`)

---

## 4. CIG (Signature) — What Is It and When Is It Needed?

The `AirFairSyncCalcSig` function calculates the CIG signature. In this codebase, it is called:

```cpp
AirFairSyncCalcSig(grappaHandle, rsData, rsSize, &sigData, &sigSize)
```

This produces the `afsync.rs.sig` file (0x15 = 21 bytes). It is the **Grappa-signed signature over the authorization response**.

**CIG is needed for DRM/app authorization** — specifically for writing the `afsync.rs.sig` file that proves the authorization response is legitimate. This is part of the Apple ID authorization flow, NOT the basic file transfer flow.

**For basic video file transfer to the TV app, the full AirFairSync flow is NOT needed.** The IpaInstall codebase only uses it for Apple ID authorization. Video transfer uses Grappa in RequestingSync but does NOT involve afsync.rq/afsync.rs files.

However, CIG signatures ARE needed for the sync plist sidecar files (`.plist.cig`), which we compute using the go-tunes CIG engine.

---

## 5. File Transfer — AFC vs ATC

### In IpaInstall: Both AFC and ATC are used for different purposes

- **ATC** (`com.apple.atc`): Used for the sync protocol (SyncAllowed → RequestingSync → ReadyForSync → MetadataSyncFinished → SyncFinished). This is the control channel.
- **AFC** (`com.apple.afc`): Used to read/write the `afsync.rq`, `afsync.rq.sig`, `afsync.rs`, `afsync.rs.sig` files at `/AirFair/sync/` on the device.
- **IPA Installation**: Uses `AMDeviceTransferApplication` (which uses AFC internally) + `AMDeviceInstallApplication` (which uses `com.apple.mobile.installation_proxy`). This is separate from the auth flow.

### For Video Transfer (our use case)

Video files are transferred through ATC using:
`SendFileBegin → [FileProgress] → SendAssetCompleted`

This is different from the IpaInstall flow which doesn't transfer video files at all.

---

## 6. What Happens After ReadyForSync

In IpaInstall's authorization flow:
1. **ReadyForSync** received — extract device Grappa from `Params.DeviceInfo.Grappa`
2. Read `afsync.rq` and `afsync.rq.sig` from device via AFC
3. Send device Grappa + afsync.rq + afsync.rq.sig to server
4. Server computes authorization response (AirFairSyncSetRequest → AccountAuthorize → GrappaUpdate → GetResponse → CalcSig)
5. Write `afsync.rs` and `afsync.rs.sig` back to device via AFC
6. Send `MetadataSyncFinished` via ATC (with `{Keybag: 1}`)
7. Wait for `SyncFinished` message

**There is NO file transfer phase in this repo** — it's purely authorization.

---

## 7. Grappa Blob Details

### Size
- Host Grappa blob: Variable size (output of `AirFairSyncGrappaCreate`)
- Device Grappa blob: **0x53 = 83 bytes** (fixed, received in ReadyForSync)
- This matches our observation of 84 bytes (possibly with length prefix)

### IpaInstall's Analysis: Session-Bound
According to IpaInstall's implementation, Grappa blobs are per-session and involve a challenge-response exchange. However, our testing proved that the **84-byte host Grappa blob is static and replayable** — the same blob (found in go-tunes) works across sessions. The device Grappa (83 bytes) does change per session and is used for CIG computation.

### MetadataSyncFinished
```cpp
ATHostConnectionSendMetadataSyncFinished(ath,
    {Keybag: 1},   // syncTypes
    {}              // dataclassAnchors (empty)
);
```

---

## 8. Relevance to mediaporter

### What applies to us:
1. **The ATC flow is the same**: SyncAllowed → RequestingSync (with Grappa) → ReadyForSync → MetadataSyncFinished → SyncFinished
2. **Grappa generation requires iTunes/AirTrafficHost internals**: Either calling internal DLL functions at offsets, or using the framework's high-level API which requires code signing
3. **RequestingSync format is confirmed**: Dataclasses, DataclassAnchors, HostInfo with Grappa/LibraryID/SyncHostName/Version

### What does NOT apply:
1. **The AirFairSync (afsync.rq/rs) flow is for DRM authorization only** — not needed for video transfer
2. **The DSID/AccountAuthorize is for Apple ID auth** — not needed for video transfer
3. **The client-server split is because of Windows DLL constraints** — on macOS we call AirTrafficHost.framework directly

### Key question answered:
**CIG/AirFairSync signatures are NOT needed for basic video file transfer.** They are only needed for DRM/app authorization. For video transfer (our use case), we need:
1. Grappa blob (replayed static 84-byte blob from go-tunes)
2. The ATC sync flow (RequestingSync → ReadyForSync → file transfer → MetadataSyncFinished)
3. CIG signatures for sync plist sidecar files (computed using go-tunes CIG engine)

### Resolution (2026-04-06):
~~Getting `AirFairSyncGrappaCreate` to work from our process.~~ SOLVED via Grappa replay — the 84-byte blob is static and replayable. Full end-to-end sync works with replayed Grappa + correct sync plist format (`is_movie: True`, Airlock staging). See `CLAUDE.md` for details.
