// Runtime loading of Apple private frameworks via dlopen/dlsym.
// Using dlopen (not linking) so the app can be notarized.

import Foundation

// MARK: - Framework Handles

/// Typed failure for a private-framework load (B2). These paths used to be
/// `fatalError` — the most likely macOS-upgrade failure mode, crashing the
/// GUI with no message. Callers gate device features on
/// `preflightPrivateFrameworks()` instead.
public enum FrameworkError: LocalizedError, Sendable {
    case libraryNotFound(String, String)      // library, dlerror/reason
    case symbolMissing(String, String)        // library, symbol

    public var errorDescription: String? {
        switch self {
        case .libraryNotFound(let lib, let why):
            return "\(lib) could not be loaded: \(why)"
        case .symbolMissing(let lib, let sym):
            return "\(lib) is missing \(sym)"
        }
    }
}

// Handles are lazily-initialized globals — Swift guarantees thread-safe
// one-time initialization, which also closes the old unsynchronized
// double-dlopen race between MainActor and detached uploader tasks (B3).
private let _mdResult: Result<UnsafeMutableRawPointer, FrameworkError> = {
    guard let handle = dlopen(
        "/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice",
        RTLD_LAZY
    ) else {
        return .failure(.libraryNotFound("MobileDevice.framework", String(cString: dlerror())))
    }
    // Suppress framework debug logging (kevent, USBMux, AFC packet traces)
    // AMDSetLogLevel doesn't cover AFC internals, so also redirect stderr
    typealias AMDSetLogLevelFn = @convention(c) (Int32) -> Void
    if let sym = dlsym(handle, "AMDSetLogLevel") {
        let setLogLevel = unsafeBitCast(sym, to: AMDSetLogLevelFn.self)
        setLogLevel(0)
    }
    redirectFrameworkStderr()
    return .success(handle)
}()

private let _athResult: Result<UnsafeMutableRawPointer, FrameworkError> = {
    // MobileDevice must be loaded first
    if case .failure(let e) = _mdResult { return .failure(e) }
    guard let handle = dlopen(
        "/System/Library/PrivateFrameworks/AirTrafficHost.framework/AirTrafficHost",
        RTLD_LAZY
    ) else {
        return .failure(.libraryNotFound("AirTrafficHost.framework", String(cString: dlerror())))
    }
    return .success(handle)
}()

private let _cigResult: Result<UnsafeMutableRawPointer, FrameworkError> = {
    guard let path = Bundle.module.path(forResource: "libcig", ofType: "dylib") else {
        return .failure(.libraryNotFound("libcig.dylib", "not found in app bundle"))
    }
    guard let handle = dlopen(path, RTLD_LAZY) else {
        return .failure(.libraryNotFound("libcig.dylib", String(cString: dlerror())))
    }
    return .success(handle)
}()

/// Load MobileDevice.framework at runtime.
func loadMobileDevice() -> UnsafeMutableRawPointer {
    switch _mdResult {
    case .success(let h): return h
    // Unreachable when the caller gated on preflightPrivateFrameworks()
    // (GUI launch check / CLI device commands) — last-resort backstop only.
    case .failure(let e): fatalError(e.localizedDescription)
    }
}

/// Load AirTrafficHost.framework at runtime.
func loadAirTrafficHost() -> UnsafeMutableRawPointer {
    switch _athResult {
    case .success(let h): return h
    case .failure(let e): fatalError(e.localizedDescription)
    }
}

/// Load libcig.dylib from the app bundle.
func loadCIG() -> UnsafeMutableRawPointer {
    switch _cigResult {
    case .success(let h): return h
    case .failure(let e): fatalError(e.localizedDescription)
    }
}

// MARK: - Preflight (B2)

// KEEP IN SYNC with the MD / ATH / CIG accessor tables below — the
// preflight is only as exhaustive as these lists.
private let _mdSymbols = [
    "AMDeviceNotificationSubscribe", "AMDeviceCopyDeviceIdentifier",
    "AMDeviceCopyValue", "AMDeviceRetain", "AMDeviceRelease",
    "AMDeviceGetInterfaceType", "AMDeviceConnect", "AMDeviceStartSession",
    "AMDeviceStartService", "AMDeviceSecureStartService",
    "AMDServiceConnectionGetSocket", "AMDServiceConnectionGetSecureIOContext",
    "AFCConnectionSetSecureContext", "AFCConnectionOpen", "AFCConnectionClose",
    "AFCDirectoryCreate", "AFCFileRefOpen", "AFCFileRefWrite", "AFCFileRefRead",
    "AFCFileRefClose", "AFCRemovePath", "AFCDirectoryOpen", "AFCDirectoryRead",
    "AFCDirectoryClose", "AFCFileInfoOpen", "AFCKeyValueRead", "AFCKeyValueClose",
]
private let _athSymbols = [
    "ATHostConnectionCreateWithLibrary", "ATHostConnectionSendHostInfo",
    "ATHostConnectionReadMessage", "ATHostConnectionSendMessage",
    "ATHostConnectionSendMetadataSyncFinished", "ATHostConnectionSendPowerAssertion",
    "ATHostConnectionInvalidate", "ATHostConnectionRelease",
    "ATCFMessageGetName", "ATCFMessageGetParam", "ATCFMessageCreate",
]
private let _cigSymbols = ["cig_calc"]

private let _preflightResult: FrameworkError? = {
    let checks: [(Result<UnsafeMutableRawPointer, FrameworkError>, String, [String])] = [
        (_mdResult, "MobileDevice.framework", _mdSymbols),
        (_athResult, "AirTrafficHost.framework", _athSymbols),
        (_cigResult, "libcig.dylib", _cigSymbols),
    ]
    for (result, lib, symbols) in checks {
        switch result {
        case .failure(let e):
            return e
        case .success(let handle):
            for sym in symbols where dlsym(handle, sym) == nil {
                return .symbolMissing(lib, sym)
            }
        }
    }
    return nil
}()

/// dlopen all three private libraries and dlsym every symbol the accessor
/// tables reference. Returns nil when everything is present; a
/// `FrameworkError` otherwise (typically after a macOS update renamed or
/// removed a private API). Cached and thread-safe. The GUI checks this at
/// launch — compatibility alert + device features disabled — and CLI
/// device commands exit nonzero, so the `fatalError` backstops in the
/// loaders and `lookup` stay unreachable.
public func preflightPrivateFrameworks() -> FrameworkError? { _preflightResult }

// MARK: - Function Lookup Helper

func lookup<T>(_ handle: UnsafeMutableRawPointer, _ name: String) -> T {
    guard let sym = dlsym(handle, name) else {
        fatalError("Symbol not found: \(name)")
    }
    return unsafeBitCast(sym, to: T.self)
}

// MARK: - MobileDevice Function Types & Accessors

enum MD {
    typealias NotificationCallback = @convention(c) (
        UnsafeRawPointer?, UnsafeMutableRawPointer?
    ) -> Void

    typealias AMDeviceNotificationSubscribeFn = @convention(c) (
        MD.NotificationCallback, UInt32, UInt32, UnsafeMutableRawPointer?,
        UnsafeMutablePointer<UnsafeMutableRawPointer?>
    ) -> Int32

    typealias AMDeviceCopyDeviceIdentifierFn = @convention(c) (UnsafeRawPointer) -> CFString?
    typealias AMDeviceCopyValueFn = @convention(c) (UnsafeRawPointer, CFString?, CFString) -> CFTypeRef?
    typealias AMDeviceRetainFn = @convention(c) (UnsafeRawPointer) -> UnsafeRawPointer?
    typealias AMDeviceReleaseFn = @convention(c) (UnsafeRawPointer) -> Void
    typealias AMDeviceConnectFn = @convention(c) (UnsafeRawPointer) -> Int32
    typealias AMDeviceStartSessionFn = @convention(c) (UnsafeRawPointer) -> Int32
    /// AMDeviceGetInterfaceType(device) → connection transport: 1 = direct/USB,
    /// 2 = indirect/Wi-Fi (network), 3 = companion-proxy. Cheap accessor on a
    /// bare attached handle (no connect/session needed).
    typealias AMDeviceGetInterfaceTypeFn = @convention(c) (UnsafeRawPointer) -> Int32
    typealias AMDeviceStartServiceFn = @convention(c) (
        UnsafeRawPointer, CFString, UnsafeMutablePointer<UnsafeMutableRawPointer?>, UnsafeRawPointer?
    ) -> Int32
    /// AMDeviceSecureStartService(device, serviceName, options, &serviceConn).
    /// The SSL-aware replacement for AMDeviceStartService. Required over Wi-Fi:
    /// network lockdown sessions are SSL-wrapped and the legacy StartService
    /// skips the SSL service handshake → 0xE8000012 (F1). `options` may be nil.
    /// Returns an AMDServiceConnectionRef (opaque) usable by AFCConnectionOpen.
    typealias AMDeviceSecureStartServiceFn = @convention(c) (
        UnsafeRawPointer, CFString, CFDictionary?, UnsafeMutablePointer<UnsafeMutableRawPointer?>
    ) -> Int32
    /// AMDServiceConnectionGetSocket(serviceConn) → raw socket fd. AFCConnectionOpen
    /// takes this fd (cast to a handle), not the AMDServiceConnectionRef.
    typealias AMDServiceConnectionGetSocketFn = @convention(c) (UnsafeRawPointer) -> Int32
    /// AMDServiceConnectionGetSecureIOContext(serviceConn) → SSL context (or nil
    /// over USB). Must be applied to the AFC connection or AFC I/O over Wi-Fi
    /// writes plaintext to an SSL socket → hangs/garbage.
    typealias AMDServiceConnectionGetSecureIOContextFn = @convention(c) (UnsafeRawPointer) -> UnsafeMutableRawPointer?
    /// AFCConnectionSetSecureContext(afcConn, sslContext) → routes AFC I/O through
    /// the service connection's SSL context. nil context = plaintext (USB).
    typealias AFCConnectionSetSecureContextFn = @convention(c) (UnsafeRawPointer, UnsafeRawPointer?) -> Int32
    typealias AFCConnectionOpenFn = @convention(c) (
        UnsafeRawPointer, UInt32, UnsafeMutablePointer<UnsafeMutableRawPointer?>
    ) -> Int32
    typealias AFCConnectionCloseFn = @convention(c) (UnsafeRawPointer) -> Int32
    typealias AFCDirectoryCreateFn = @convention(c) (UnsafeRawPointer, UnsafePointer<CChar>) -> Int32
    typealias AFCFileRefOpenFn = @convention(c) (
        UnsafeRawPointer, UnsafePointer<CChar>, Int32, UnsafeMutablePointer<Int>
    ) -> Int32
    typealias AFCFileRefWriteFn = @convention(c) (UnsafeRawPointer, Int, UnsafeRawPointer, Int) -> Int32
    /// AFCFileRefRead(connection, fileRef, buffer, lengthInOut) — `lengthInOut`
    /// is in/out: in = max bytes to read; out = bytes actually read.
    typealias AFCFileRefReadFn = @convention(c) (
        UnsafeRawPointer, Int, UnsafeMutableRawPointer, UnsafeMutablePointer<Int>
    ) -> Int32
    typealias AFCFileRefCloseFn = @convention(c) (UnsafeRawPointer, Int) -> Int32
    typealias AFCRemovePathFn = @convention(c) (UnsafeRawPointer, UnsafePointer<CChar>) -> Int32
    typealias AFCDirectoryOpenFn = @convention(c) (
        UnsafeRawPointer, UnsafePointer<CChar>, UnsafeMutablePointer<UnsafeMutableRawPointer?>
    ) -> Int32
    typealias AFCDirectoryReadFn = @convention(c) (
        UnsafeRawPointer, UnsafeRawPointer, UnsafeMutablePointer<UnsafePointer<CChar>?>
    ) -> Int32
    typealias AFCDirectoryCloseFn = @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> Int32
    typealias AFCFileInfoOpenFn = @convention(c) (
        UnsafeRawPointer, UnsafePointer<CChar>, UnsafeMutablePointer<UnsafeMutableRawPointer?>
    ) -> Int32
    typealias AFCKeyValueReadFn = @convention(c) (
        UnsafeRawPointer,
        UnsafeMutablePointer<UnsafePointer<CChar>?>,
        UnsafeMutablePointer<UnsafePointer<CChar>?>
    ) -> Int32
    typealias AFCKeyValueCloseFn = @convention(c) (UnsafeRawPointer) -> Int32

    static var subscribe: AMDeviceNotificationSubscribeFn { lookup(loadMobileDevice(), "AMDeviceNotificationSubscribe") }
    static var copyID: AMDeviceCopyDeviceIdentifierFn { lookup(loadMobileDevice(), "AMDeviceCopyDeviceIdentifier") }
    static var copyValue: AMDeviceCopyValueFn { lookup(loadMobileDevice(), "AMDeviceCopyValue") }
    static var retain: AMDeviceRetainFn { lookup(loadMobileDevice(), "AMDeviceRetain") }
    static var release: AMDeviceReleaseFn { lookup(loadMobileDevice(), "AMDeviceRelease") }
    static var getInterfaceType: AMDeviceGetInterfaceTypeFn { lookup(loadMobileDevice(), "AMDeviceGetInterfaceType") }
    static var connect: AMDeviceConnectFn { lookup(loadMobileDevice(), "AMDeviceConnect") }
    static var startSession: AMDeviceStartSessionFn { lookup(loadMobileDevice(), "AMDeviceStartSession") }
    static var startService: AMDeviceStartServiceFn { lookup(loadMobileDevice(), "AMDeviceStartService") }
    static var secureStartService: AMDeviceSecureStartServiceFn { lookup(loadMobileDevice(), "AMDeviceSecureStartService") }
    static var serviceConnectionGetSocket: AMDServiceConnectionGetSocketFn { lookup(loadMobileDevice(), "AMDServiceConnectionGetSocket") }
    static var serviceConnectionGetSecureIOContext: AMDServiceConnectionGetSecureIOContextFn { lookup(loadMobileDevice(), "AMDServiceConnectionGetSecureIOContext") }
    static var afcSetSecureContext: AFCConnectionSetSecureContextFn { lookup(loadMobileDevice(), "AFCConnectionSetSecureContext") }
    static var afcOpen: AFCConnectionOpenFn { lookup(loadMobileDevice(), "AFCConnectionOpen") }
    static var afcClose: AFCConnectionCloseFn { lookup(loadMobileDevice(), "AFCConnectionClose") }
    static var afcMkdir: AFCDirectoryCreateFn { lookup(loadMobileDevice(), "AFCDirectoryCreate") }
    static var afcFileOpen: AFCFileRefOpenFn { lookup(loadMobileDevice(), "AFCFileRefOpen") }
    static var afcFileWrite: AFCFileRefWriteFn { lookup(loadMobileDevice(), "AFCFileRefWrite") }
    static var afcFileRead: AFCFileRefReadFn { lookup(loadMobileDevice(), "AFCFileRefRead") }
    static var afcFileClose: AFCFileRefCloseFn { lookup(loadMobileDevice(), "AFCFileRefClose") }
    static var afcRemove: AFCRemovePathFn { lookup(loadMobileDevice(), "AFCRemovePath") }
    static var afcDirOpen: AFCDirectoryOpenFn { lookup(loadMobileDevice(), "AFCDirectoryOpen") }
    static var afcDirRead: AFCDirectoryReadFn { lookup(loadMobileDevice(), "AFCDirectoryRead") }
    static var afcDirClose: AFCDirectoryCloseFn { lookup(loadMobileDevice(), "AFCDirectoryClose") }
    static var afcFileInfoOpen: AFCFileInfoOpenFn { lookup(loadMobileDevice(), "AFCFileInfoOpen") }
    static var afcKeyValueRead: AFCKeyValueReadFn { lookup(loadMobileDevice(), "AFCKeyValueRead") }
    static var afcKeyValueClose: AFCKeyValueCloseFn { lookup(loadMobileDevice(), "AFCKeyValueClose") }
}

// MARK: - AirTrafficHost Function Types & Accessors

enum ATH {
    typealias CreateFn = @convention(c) (CFString, CFString, UInt32) -> UnsafeMutableRawPointer?
    typealias SendHostInfoFn = @convention(c) (UnsafeRawPointer, CFDictionary) -> Int32
    typealias ReadMessageFn = @convention(c) (UnsafeRawPointer) -> UnsafeMutableRawPointer?
    typealias SendMessageFn = @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> Int32
    typealias SendMetadataSyncFinishedFn = @convention(c) (
        UnsafeRawPointer, CFDictionary, CFDictionary
    ) -> Int32
    typealias SendPowerAssertionFn = @convention(c) (UnsafeRawPointer, CFBoolean) -> Int32
    typealias InvalidateFn = @convention(c) (UnsafeRawPointer) -> Int32
    typealias ReleaseFn = @convention(c) (UnsafeRawPointer) -> Void
    typealias MessageGetNameFn = @convention(c) (UnsafeRawPointer) -> CFString?
    typealias MessageGetParamFn = @convention(c) (UnsafeRawPointer, CFString) -> UnsafeMutableRawPointer?
    typealias MessageCreateFn = @convention(c) (UInt32, CFString, CFDictionary) -> UnsafeMutableRawPointer?

    static var create: CreateFn { lookup(loadAirTrafficHost(), "ATHostConnectionCreateWithLibrary") }
    static var sendHostInfo: SendHostInfoFn { lookup(loadAirTrafficHost(), "ATHostConnectionSendHostInfo") }
    static var readMessage: ReadMessageFn { lookup(loadAirTrafficHost(), "ATHostConnectionReadMessage") }
    static var sendMessage: SendMessageFn { lookup(loadAirTrafficHost(), "ATHostConnectionSendMessage") }
    static var sendMetadataSyncFinished: SendMetadataSyncFinishedFn {
        lookup(loadAirTrafficHost(), "ATHostConnectionSendMetadataSyncFinished")
    }
    static var sendPowerAssertion: SendPowerAssertionFn {
        lookup(loadAirTrafficHost(), "ATHostConnectionSendPowerAssertion")
    }
    static var invalidate: InvalidateFn { lookup(loadAirTrafficHost(), "ATHostConnectionInvalidate") }
    static var release: ReleaseFn { lookup(loadAirTrafficHost(), "ATHostConnectionRelease") }
    static var messageName: MessageGetNameFn { lookup(loadAirTrafficHost(), "ATCFMessageGetName") }
    static var messageParam: MessageGetParamFn { lookup(loadAirTrafficHost(), "ATCFMessageGetParam") }
    static var messageCreate: MessageCreateFn { lookup(loadAirTrafficHost(), "ATCFMessageCreate") }
}

// MARK: - CIG

enum CIG {
    typealias CalcFn = @convention(c) (
        UnsafePointer<UInt8>, UnsafePointer<UInt8>, Int32,
        UnsafeMutablePointer<UInt8>, UnsafeMutablePointer<Int32>
    ) -> Int32

    static var calc: CalcFn { lookup(loadCIG(), "cig_calc") }
}

// MARK: - Sync Auth Seed

enum SyncAuthSeed {
    static let resourceName = "SyncAuthSeed"
    static let fileExtension = "dat"
    static let pathEnv = "MEDIAPORTER_SYNC_AUTH_SEED_PATH"
    static let base64Env = "MEDIAPORTER_SYNC_AUTH_SEED_B64"

    // Bundled seed is XOR-masked so it doesn't byte-match the well-known
    // raw blob on code-search engines. Trivially reversible; the goal is
    // signature evasion, not secrecy.
    static let mask: [UInt8] = [
        0x37, 0xC1, 0x5A, 0xA5, 0x9E, 0x42, 0x6B, 0xD8,
        0x11, 0x7F, 0xE3, 0x04, 0x88, 0x2A, 0xB6, 0x59,
    ]

    static func unmask(_ data: Data) -> Data {
        var out = Data(count: data.count)
        for i in 0..<data.count {
            out[i] = data[i] ^ mask[i % mask.count]
        }
        return out
    }
}

func loadSyncAuthSeed() throws -> Data {
    let env = ProcessInfo.processInfo.environment

    if let b64 = env[SyncAuthSeed.base64Env]?.trimmingCharacters(in: .whitespacesAndNewlines),
       !b64.isEmpty,
       let data = Data(base64Encoded: b64) {
        return data
    }

    if let path = env[SyncAuthSeed.pathEnv], !path.isEmpty {
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    if let url = Bundle.module.url(
        forResource: SyncAuthSeed.resourceName,
        withExtension: SyncAuthSeed.fileExtension
    ) {
        return SyncAuthSeed.unmask(try Data(contentsOf: url))
    }

    throw SyncError.handshakeFailed(
        "Missing bundled sync auth seed (and no \(SyncAuthSeed.pathEnv)/\(SyncAuthSeed.base64Env) override)."
    )
}

// MARK: - Stderr Redirect

/// Where framework stderr lands after the redirect. Included in Send
/// Diagnostic alongside the debug log.
public let frameworkStderrLogPath = "/tmp/mediaporter-stderr.log"

/// Original stderr, saved before the redirect. -1 until the redirect runs.
/// Written once from the `_mdResult` lazy initializer (thread-safe init),
/// read-only afterwards.
private var _originalStderr: Int32 = -1

/// Redirect stderr to a bounded log file to keep MobileDevice.framework
/// debug spam (kevent/AFC/USBMux traces on fd 2) out of the terminal.
///
/// B3: this used to point at /dev/null, which permanently destroyed ALL
/// fd-2 output for the process — including Swift runtime crash reasons —
/// after the first device touch. dup2 is process-global, and the framework
/// keeps writing to fd 2 for the connection's lifetime, so a scoped
/// save/restore can't work; a file keeps the bytes recoverable instead.
/// Truncated at each redirect (once per launch). Called only from the
/// `_mdResult` initializer, so the one-shot guard is the lazy-global init.
private func redirectFrameworkStderr() {
    _originalStderr = dup(STDERR_FILENO)
    let fd = open(frameworkStderrLogPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    if fd >= 0 {
        dup2(fd, STDERR_FILENO)
        close(fd)
    }
}

/// Write a user-facing line to the REAL terminal stderr, bypassing the
/// framework redirect (before any redirect this is just stderr). The CLI
/// uses this for its error messages — without it they'd silently land in
/// the framework log file the moment a device call has been made.
public func writeUserStderr(_ line: String) {
    let fd = _originalStderr >= 0 ? _originalStderr : STDERR_FILENO
    let out = line.hasSuffix("\n") ? line : line + "\n"
    Array(out.utf8).withUnsafeBufferPointer { buf in
        _ = write(fd, buf.baseAddress, buf.count)
    }
}
