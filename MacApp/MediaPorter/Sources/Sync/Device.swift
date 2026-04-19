// iOS device discovery via MobileDevice.framework.

import Foundation

public struct DeviceInfo {
    public let udid: String
    public let handle: UnsafeRawPointer
    public var deviceName: String = "iOS Device"
    public var productType: String = ""      // e.g. "iPad13,4", "iPhone15,2"
    public var productVersion: String = ""   // e.g. "17.4.1"
    public var deviceClass: String = ""      // "iPad", "iPhone", "iPod"
    public var modelNumber: String = ""
    public var screenPixelHeight: Int = 2048 // native pixel height (longest edge)
    public var screenScale: Int = 2          // retina scale factor (2x or 3x)
}

// MARK: - Device Model Table
//
// ProductType → (friendly name, native display resolution in "WxH" form).
// Ported from src/mediaporter/sync/device.py — covers common iPads and iPhones
// from ~2019 onward. Unknown product types fall back to the raw identifier.

private let deviceModels: [String: (name: String, resolution: String)] = [
    // iPads
    "iPad7,1": ("iPad Pro 12.9\" (2nd gen)", "2732x2048"),
    "iPad7,2": ("iPad Pro 12.9\" (2nd gen)", "2732x2048"),
    "iPad7,3": ("iPad Pro 10.5\"", "2224x1668"),
    "iPad7,4": ("iPad Pro 10.5\"", "2224x1668"),
    "iPad7,5": ("iPad (6th gen)", "2048x1536"),
    "iPad7,6": ("iPad (6th gen)", "2048x1536"),
    "iPad7,11": ("iPad (7th gen)", "2160x1620"),
    "iPad7,12": ("iPad (7th gen)", "2160x1620"),
    "iPad8,1": ("iPad Pro 11\" (1st gen)", "2388x1668"),
    "iPad8,2": ("iPad Pro 11\" (1st gen)", "2388x1668"),
    "iPad8,3": ("iPad Pro 11\" (1st gen)", "2388x1668"),
    "iPad8,4": ("iPad Pro 11\" (1st gen)", "2388x1668"),
    "iPad8,5": ("iPad Pro 12.9\" (3rd gen)", "2732x2048"),
    "iPad8,6": ("iPad Pro 12.9\" (3rd gen)", "2732x2048"),
    "iPad8,7": ("iPad Pro 12.9\" (3rd gen)", "2732x2048"),
    "iPad8,8": ("iPad Pro 12.9\" (3rd gen)", "2732x2048"),
    "iPad8,9": ("iPad Pro 11\" (2nd gen)", "2388x1668"),
    "iPad8,10": ("iPad Pro 11\" (2nd gen)", "2388x1668"),
    "iPad8,11": ("iPad Pro 12.9\" (4th gen)", "2732x2048"),
    "iPad8,12": ("iPad Pro 12.9\" (4th gen)", "2732x2048"),
    "iPad11,1": ("iPad mini (5th gen)", "2048x1536"),
    "iPad11,2": ("iPad mini (5th gen)", "2048x1536"),
    "iPad11,3": ("iPad Air (3rd gen)", "2224x1668"),
    "iPad11,4": ("iPad Air (3rd gen)", "2224x1668"),
    "iPad11,6": ("iPad (8th gen)", "2160x1620"),
    "iPad11,7": ("iPad (8th gen)", "2160x1620"),
    "iPad12,1": ("iPad (9th gen)", "2160x1620"),
    "iPad12,2": ("iPad (9th gen)", "2160x1620"),
    "iPad13,1": ("iPad Air (4th gen)", "2360x1640"),
    "iPad13,2": ("iPad Air (4th gen)", "2360x1640"),
    "iPad13,4": ("iPad Pro 11\" (3rd gen)", "2388x1668"),
    "iPad13,5": ("iPad Pro 11\" (3rd gen)", "2388x1668"),
    "iPad13,6": ("iPad Pro 11\" (3rd gen)", "2388x1668"),
    "iPad13,7": ("iPad Pro 11\" (3rd gen)", "2388x1668"),
    "iPad13,8": ("iPad Pro 12.9\" (5th gen)", "2732x2048"),
    "iPad13,9": ("iPad Pro 12.9\" (5th gen)", "2732x2048"),
    "iPad13,10": ("iPad Pro 12.9\" (5th gen)", "2732x2048"),
    "iPad13,11": ("iPad Pro 12.9\" (5th gen)", "2732x2048"),
    "iPad13,16": ("iPad Air (5th gen)", "2360x1640"),
    "iPad13,17": ("iPad Air (5th gen)", "2360x1640"),
    "iPad13,18": ("iPad (10th gen)", "2360x1640"),
    "iPad13,19": ("iPad (10th gen)", "2360x1640"),
    "iPad14,1": ("iPad mini (6th gen)", "2266x1488"),
    "iPad14,2": ("iPad mini (6th gen)", "2266x1488"),
    "iPad14,3": ("iPad Pro 11\" (4th gen)", "2388x1668"),
    "iPad14,4": ("iPad Pro 11\" (4th gen)", "2388x1668"),
    "iPad14,5": ("iPad Pro 12.9\" (6th gen)", "2732x2048"),
    "iPad14,6": ("iPad Pro 12.9\" (6th gen)", "2732x2048"),
    "iPad14,8": ("iPad Air 11\" (M2)", "2360x1640"),
    "iPad14,9": ("iPad Air 11\" (M2)", "2360x1640"),
    "iPad14,10": ("iPad Air 13\" (M2)", "2732x2048"),
    "iPad14,11": ("iPad Air 13\" (M2)", "2732x2048"),
    "iPad16,3": ("iPad Pro 11\" (M4)", "2420x1668"),
    "iPad16,4": ("iPad Pro 11\" (M4)", "2420x1668"),
    "iPad16,5": ("iPad Pro 13\" (M4)", "2752x2064"),
    "iPad16,6": ("iPad Pro 13\" (M4)", "2752x2064"),
    // iPhones
    "iPhone11,2": ("iPhone XS", "2436x1125"),
    "iPhone11,4": ("iPhone XS Max", "2688x1242"),
    "iPhone11,6": ("iPhone XS Max", "2688x1242"),
    "iPhone11,8": ("iPhone XR", "1792x828"),
    "iPhone12,1": ("iPhone 11", "1792x828"),
    "iPhone12,3": ("iPhone 11 Pro", "2436x1125"),
    "iPhone12,5": ("iPhone 11 Pro Max", "2688x1242"),
    "iPhone12,8": ("iPhone SE (2nd gen)", "1334x750"),
    "iPhone13,1": ("iPhone 12 mini", "2340x1080"),
    "iPhone13,2": ("iPhone 12", "2532x1170"),
    "iPhone13,3": ("iPhone 12 Pro", "2532x1170"),
    "iPhone13,4": ("iPhone 12 Pro Max", "2778x1284"),
    "iPhone14,2": ("iPhone 13 Pro", "2532x1170"),
    "iPhone14,3": ("iPhone 13 Pro Max", "2778x1284"),
    "iPhone14,4": ("iPhone 13 mini", "2340x1080"),
    "iPhone14,5": ("iPhone 13", "2532x1170"),
    "iPhone14,6": ("iPhone SE (3rd gen)", "1334x750"),
    "iPhone14,7": ("iPhone 14", "2532x1170"),
    "iPhone14,8": ("iPhone 14 Plus", "2778x1284"),
    "iPhone15,2": ("iPhone 14 Pro", "2556x1179"),
    "iPhone15,3": ("iPhone 14 Pro Max", "2796x1290"),
    "iPhone15,4": ("iPhone 15", "2556x1179"),
    "iPhone15,5": ("iPhone 15 Plus", "2796x1290"),
    "iPhone16,1": ("iPhone 15 Pro", "2556x1179"),
    "iPhone16,2": ("iPhone 15 Pro Max", "2796x1290"),
    "iPhone17,1": ("iPhone 16 Pro", "2622x1206"),
    "iPhone17,2": ("iPhone 16 Pro Max", "2868x1320"),
    "iPhone17,3": ("iPhone 16", "2556x1179"),
    "iPhone17,4": ("iPhone 16 Plus", "2796x1290"),
]

extension DeviceInfo {
    /// Effective point height = pixels / scale. This is what matters for video.
    public var screenPointHeight: Int { screenPixelHeight / screenScale }

    /// Optimal video resolution for this device.
    /// Based on effective point resolution — no benefit encoding above this.
    ///
    /// Device reference (all retina):
    /// - iPad Pro 12.9"  : 2732px / 2x = 1366pt → 1080p optimal
    /// - iPad Pro 11"    : 2388px / 2x = 1194pt → 1080p optimal
    /// - iPad Air        : 2360px / 2x = 1180pt → 1080p optimal
    /// - iPad mini       : 2266px / 2x = 1133pt → 1080p optimal
    /// - iPad (standard) : 2160px / 2x = 1080pt → 1080p optimal
    /// - iPhone Pro Max  : 2796px / 3x =  932pt → 1080p (landscape video fills ~932pt)
    /// - iPhone Pro/Reg  : 2556px / 3x =  852pt → 720p-1080p
    /// - iPhone SE/mini  : 2340px / 3x =  780pt → 720p
    public var suggestedResolution: ResolutionLimit {
        let pts = screenPointHeight
        if pts <= 750 { return .hd }     // iPhone SE/mini → 720p
        return .fhd                       // Everything else → 1080p
    }

    /// Short screen description for the status bar.
    public var screenDescription: String {
        "\(screenPixelHeight / screenScale)p"
    }

    /// Friendly model name from the product-type table, or the raw ProductType if unknown.
    public var modelName: String {
        if let entry = deviceModels[productType] { return entry.name }
        return productType.isEmpty ? (deviceClass.isEmpty ? "iOS Device" : deviceClass) : productType
    }

    /// Native display resolution (e.g. "2732x2048") if known.
    public var nativeResolution: String? { deviceModels[productType]?.resolution }

    /// Recommended transcode target. 1080p plays natively on every shipped iPad/iPhone
    /// and is indistinguishable from 2K+ source at typical viewing distances.
    public var optimalTranscodeResolution: String { "1920x1080 (1080p H.264/HEVC)" }

    /// Human-readable device description — prefers user-set DeviceName, falls back to model name.
    public var displayName: String {
        if !deviceName.isEmpty && deviceName != "iOS Device" {
            return deviceName
        }
        return modelName
    }
}

public enum DeviceError: LocalizedError {
    case notFound

    public var errorDescription: String? {
        switch self {
        case .notFound: return "No iOS device found. Is your device connected and trusted?"
        }
    }
}

// MARK: - Device Property Query

/// Read a string property from a connected device.
private func readDeviceValue(_ device: UnsafeRawPointer, key: String) -> String? {
    // Must connect + start session to read values
    guard MD.connect(device) == 0 else { return nil }
    defer { /* session will be reused */ }
    guard MD.startSession(device) == 0 else { return nil }

    guard let val = MD.copyValue(device, nil, key as CFString) else { return nil }
    if CFGetTypeID(val) == CFStringGetTypeID() {
        return (val as! CFString) as String
    }
    return nil
}

/// Query device properties and build a full DeviceInfo.
private func queryDeviceInfo(device: UnsafeRawPointer, udid: String) -> DeviceInfo {
    var info = DeviceInfo(udid: udid, handle: device)

    info.deviceName = readDeviceValue(device, key: "DeviceName") ?? "iOS Device"
    info.productType = readDeviceValue(device, key: "ProductType") ?? ""
    info.productVersion = readDeviceValue(device, key: "ProductVersion") ?? ""
    info.deviceClass = readDeviceValue(device, key: "DeviceClass") ?? ""
    info.modelNumber = readDeviceValue(device, key: "ModelNumber") ?? ""

    // Map product types to screen specs
    let (pixels, scale) = screenSpecsForProduct(info.productType, deviceClass: info.deviceClass)
    info.screenPixelHeight = pixels
    info.screenScale = scale

    return info
}

/// Query (freeBytes, totalBytes) from the device via the lockdown `com.apple.disk_usage`
/// domain. Returns nil if connection/session/values fail. Mirrors Python's
/// `query_device_disk_space()`.
public func queryDeviceDiskSpace(device: UnsafeRawPointer) -> (free: Int64, total: Int64)? {
    guard MD.connect(device) == 0 else { return nil }
    defer { /* framework manages connection lifecycle */ }
    guard MD.startSession(device) == 0 else { return nil }

    let domain = "com.apple.disk_usage" as CFString
    let totalRef = MD.copyValue(device, domain, "TotalDiskCapacity" as CFString)
    let freeRef = MD.copyValue(device, domain, "AmountDataAvailable" as CFString)

    func asInt64(_ ref: CFTypeRef?) -> Int64? {
        guard let ref else { return nil }
        if CFGetTypeID(ref) != CFNumberGetTypeID() { return nil }
        var v: Int64 = 0
        guard CFNumberGetValue((ref as! CFNumber), .sInt64Type, &v) else { return nil }
        return v
    }
    guard let total = asInt64(totalRef), let free = asInt64(freeRef) else { return nil }
    return (free, total)
}

/// Map ProductType to (pixel height, scale factor).
private func screenSpecsForProduct(_ productType: String, deviceClass: String) -> (Int, Int) {
    let dc = deviceClass.lowercased()

    if dc == "ipad" {
        // All iPads are 2x retina
        // iPad Pro 12.9" → 2732px
        // iPad Pro 11" → 2388px
        // iPad Air / iPad 10th gen → 2360px
        // iPad mini → 2266px
        // Older/standard iPads → 2160px
        // For video purposes, all iPads → 1080p optimal (points: 1080-1366)
        let pt = productType.lowercased()
        if pt.contains("ipad6,7") || pt.contains("ipad6,8") ||
           pt.contains("ipad7,1") || pt.contains("ipad7,2") ||
           pt.contains("ipad8,5") || pt.contains("ipad8,6") ||
           pt.contains("ipad8,7") || pt.contains("ipad8,8") ||
           pt.contains("ipad8,11") || pt.contains("ipad8,12") ||
           pt.contains("ipad13,8") || pt.contains("ipad13,9") ||
           pt.contains("ipad13,10") || pt.contains("ipad13,11") ||
           pt.contains("ipad14,5") || pt.contains("ipad14,6") ||
           pt.contains("ipad16,3") || pt.contains("ipad16,4") ||
           pt.contains("ipad16,5") || pt.contains("ipad16,6") {
            return (2732, 2) // 12.9" Pro → 1366pt
        }
        if pt.contains("ipad14,1") || pt.contains("ipad14,2") {
            return (2266, 2) // mini → 1133pt
        }
        return (2360, 2) // Air/standard → 1180pt
    }

    if dc == "iphone" {
        // All modern iPhones are 3x retina
        // Pro Max / Plus (6.7") → 2796px / 3 = 932pt
        // Pro / Regular (6.1") → 2556px / 3 = 852pt
        // SE → 1334px / 2 = 667pt (2x, not 3x)
        // mini → 2340px / 3 = 780pt
        let pt = productType.lowercased()
        if pt.contains("iphone8,4") || pt.contains("iphone12,8") || pt.contains("iphone14,6") {
            return (1334, 2) // iPhone SE (2x retina)
        }
        return (2556, 3) // Most modern iPhones
    }

    if dc == "ipod" {
        return (1136, 2)
    }

    return (2048, 2)  // safe default
}

// MARK: - Persistent Device Monitor

public class DeviceMonitor {
    public static let shared = DeviceMonitor()

    public var currentDevice: DeviceInfo?
    private var started = false
    private let lock = NSLock()

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        started = true

        let thread = Thread {
            var subscription: UnsafeMutableRawPointer?
            _ = MD.subscribe(_monitorCallback, 0, 0, nil, &subscription)
            while true {
                CFRunLoopRunInMode(.defaultMode, 1.0, false)
            }
        }
        thread.name = "DeviceMonitor"
        thread.qualityOfService = .utility
        thread.start()
    }
}

private let _monitorCallback: MD.NotificationCallback = { infoPtr, _ in
    guard let info = infoPtr else { return }
    let device = info.load(as: UnsafeRawPointer?.self)
    guard let dev = device else { return }

    let msgType = info.load(fromByteOffset: MemoryLayout<UnsafeRawPointer>.size, as: Int32.self)

    if msgType == 1 {
        _ = MD.retain(dev)
        if let cfUDID = MD.copyID(dev) {
            let udid = cfUDID as String
            let deviceInfo = queryDeviceInfo(device: dev, udid: udid)
            DeviceMonitor.shared.currentDevice = deviceInfo
        }
    } else if msgType == 2 {
        DeviceMonitor.shared.currentDevice = nil
    }
}

// MARK: - One-shot discovery

private var _oneshotDevice: UnsafeRawPointer?
private var _oneshotUDID: String?

private let _oneshotCallback: MD.NotificationCallback = { infoPtr, _ in
    guard let info = infoPtr, _oneshotDevice == nil else { return }
    let device = info.load(as: UnsafeRawPointer?.self)
    guard let dev = device else { return }
    _ = MD.retain(dev)
    _oneshotDevice = dev
    if let cfUDID = MD.copyID(dev) {
        _oneshotUDID = cfUDID as String
    }
}

public func discoverDevice(timeout: TimeInterval = 5.0) throws -> DeviceInfo {
    if let device = DeviceMonitor.shared.currentDevice {
        return device
    }

    _oneshotDevice = nil
    _oneshotUDID = nil

    var subscription: UnsafeMutableRawPointer?
    _ = MD.subscribe(_oneshotCallback, 0, 0, nil, &subscription)

    let iterations = Int(timeout / 0.1)
    for _ in 0..<iterations {
        CFRunLoopRunInMode(.defaultMode, 0.1, false)
        if _oneshotDevice != nil { break }
    }

    guard let device = _oneshotDevice, let udid = _oneshotUDID else {
        throw DeviceError.notFound
    }

    let info = queryDeviceInfo(device: device, udid: udid)
    DeviceMonitor.shared.currentDevice = info
    return info
}
