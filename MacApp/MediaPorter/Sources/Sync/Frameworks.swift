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
    typealias AMDeviceConnectFn = @convention(c) (UnsafeRawPointer) -> Int32
    typealias AMDeviceStartSessionFn = @convention(c) (UnsafeRawPointer) -> Int32
    typealias AMDeviceStartServiceFn = @convention(c) (
        UnsafeRawPointer, CFString, UnsafeMutablePointer<UnsafeMutableRawPointer?>, UnsafeRawPointer?
    ) -> Int32
    typealias AFCConnectionOpenFn = @convention(c) (
        UnsafeRawPointer, UInt32, UnsafeMutablePointer<UnsafeMutableRawPointer?>
    ) -> Int32
    typealias AFCConnectionCloseFn = @convention(c) (UnsafeRawPointer) -> Int32
    typealias AFCDirectoryCreateFn = @convention(c) (UnsafeRawPointer, UnsafePointer<CChar>) -> Int32
    typealias AFCFileRefOpenFn = @convention(c) (
        UnsafeRawPointer, UnsafePointer<CChar>, Int32, UnsafeMutablePointer<Int>
    ) -> Int32
    typealias AFCFileRefWriteFn = @convention(c) (UnsafeRawPointer, Int, UnsafeRawPointer, Int) -> Int32
    typealias AFCFileRefCloseFn = @convention(c) (UnsafeRawPointer, Int) -> Int32
    typealias AFCRemovePathFn = @convention(c) (UnsafeRawPointer, UnsafePointer<CChar>) -> Int32

    static var subscribe: AMDeviceNotificationSubscribeFn { lookup(loadMobileDevice(), "AMDeviceNotificationSubscribe") }
    static var copyID: AMDeviceCopyDeviceIdentifierFn { lookup(loadMobileDevice(), "AMDeviceCopyDeviceIdentifier") }
    static var copyValue: AMDeviceCopyValueFn { lookup(loadMobileDevice(), "AMDeviceCopyValue") }
    static var retain: AMDeviceRetainFn { lookup(loadMobileDevice(), "AMDeviceRetain") }
    static var connect: AMDeviceConnectFn { lookup(loadMobileDevice(), "AMDeviceConnect") }
    static var startSession: AMDeviceStartSessionFn { lookup(loadMobileDevice(), "AMDeviceStartSession") }
    static var startService: AMDeviceStartServiceFn { lookup(loadMobileDevice(), "AMDeviceStartService") }
    static var afcOpen: AFCConnectionOpenFn { lookup(loadMobileDevice(), "AFCConnectionOpen") }
    static var afcClose: AFCConnectionCloseFn { lookup(loadMobileDevice(), "AFCConnectionClose") }
    static var afcMkdir: AFCDirectoryCreateFn { lookup(loadMobileDevice(), "AFCDirectoryCreate") }
    static var afcFileOpen: AFCFileRefOpenFn { lookup(loadMobileDevice(), "AFCFileRefOpen") }
    static var afcFileWrite: AFCFileRefWriteFn { lookup(loadMobileDevice(), "AFCFileRefWrite") }
    static var afcFileClose: AFCFileRefCloseFn { lookup(loadMobileDevice(), "AFCFileRefClose") }
    static var afcRemove: AFCRemovePathFn { lookup(loadMobileDevice(), "AFCRemovePath") }
}

// MARK: - AirTrafficHost Function Types & Accessors

enum ATH {
    typealias CreateFn = @convention(c) (CFString, CFString, UInt32) -> UnsafeMutableRawPointer?
    typealias SendHostInfoFn = @convention(c) (UnsafeRawPointer, CFDictionary) -> UnsafeRawPointer?
    typealias ReadMessageFn = @convention(c) (UnsafeRawPointer) -> UnsafeMutableRawPointer?
    typealias SendMessageFn = @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> Int32
    typealias SendMetadataSyncFinishedFn = @convention(c) (
        UnsafeRawPointer, CFDictionary, CFDictionary
    ) -> UnsafeRawPointer?
    typealias SendPowerAssertionFn = @convention(c) (UnsafeRawPointer, CFBoolean) -> UnsafeRawPointer?
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

// MARK: - Grappa Blob

func loadGrappaBlob() -> Data {
    let bundle = Bundle.module
    guard let url = bundle.url(forResource: "grappa", withExtension: "bin") else {
        fatalError("grappa.bin not found in app bundle")
    }
    return try! Data(contentsOf: url)
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
