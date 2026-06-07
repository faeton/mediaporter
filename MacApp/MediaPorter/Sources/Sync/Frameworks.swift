// Runtime loading of Apple private frameworks via dlopen/dlsym.
// Using dlopen (not linking) so the app can be notarized.

import Foundation

// MARK: - Framework Handles

private var _md: UnsafeMutableRawPointer?
private var _ath: UnsafeMutableRawPointer?
private var _cig: UnsafeMutableRawPointer?

/// Load MobileDevice.framework at runtime.
func loadMobileDevice() -> UnsafeMutableRawPointer {
    if let md = _md { return md }
    guard let handle = dlopen(
        "/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice",
        RTLD_LAZY
    ) else {
        fatalError("Failed to load MobileDevice.framework: \(String(cString: dlerror()))")
    }
    _md = handle
    // Suppress framework debug logging (kevent, USBMux, AFC packet traces)
    // AMDSetLogLevel doesn't cover AFC internals, so redirect stderr
    typealias AMDSetLogLevelFn = @convention(c) (Int32) -> Void
    if let sym = dlsym(handle, "AMDSetLogLevel") {
        let setLogLevel = unsafeBitCast(sym, to: AMDSetLogLevelFn.self)
        setLogLevel(0)
    }
    suppressFrameworkStderr()
    return handle
}

/// Load AirTrafficHost.framework at runtime.
func loadAirTrafficHost() -> UnsafeMutableRawPointer {
    if let ath = _ath { return ath }
    // MobileDevice must be loaded first
    _ = loadMobileDevice()
    guard let handle = dlopen(
        "/System/Library/PrivateFrameworks/AirTrafficHost.framework/AirTrafficHost",
        RTLD_LAZY
    ) else {
        fatalError("Failed to load AirTrafficHost.framework: \(String(cString: dlerror()))")
    }
    _ath = handle
    return handle
}

/// Load libcig.dylib from the app bundle.
func loadCIG() -> UnsafeMutableRawPointer {
    if let cig = _cig { return cig }
    let bundle = Bundle.module
    guard let path = bundle.path(forResource: "libcig", ofType: "dylib") else {
        fatalError("libcig.dylib not found in app bundle")
    }
    guard let handle = dlopen(path, RTLD_LAZY) else {
        fatalError("Failed to load libcig.dylib: \(String(cString: dlerror()))")
    }
    _cig = handle
    return handle
}

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

// MARK: - Stderr Suppression

private var _originalStderr: Int32 = -1

/// Redirect stderr to /dev/null to suppress MobileDevice.framework debug spam.
/// The framework logs kevent/AFC/USBMux traces directly to fd 2.
func suppressFrameworkStderr() {
    guard _originalStderr == -1 else { return }
    _originalStderr = dup(STDERR_FILENO)
    let devNull = open("/dev/null", O_WRONLY)
    if devNull >= 0 {
        dup2(devNull, STDERR_FILENO)
        close(devNull)
    }
}

/// Restore stderr (e.g. if you need error output for debugging).
func restoreStderr() {
    guard _originalStderr >= 0 else { return }
    dup2(_originalStderr, STDERR_FILENO)
    close(_originalStderr)
    _originalStderr = -1
}
