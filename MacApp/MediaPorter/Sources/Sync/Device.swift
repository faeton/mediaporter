// iOS device discovery via MobileDevice.framework.

import Foundation

struct DeviceInfo {
    let udid: String
    let handle: UnsafeRawPointer
    var deviceName: String = "iOS Device"
    var productType: String = ""      // e.g. "iPad13,4", "iPhone15,2"
    var deviceClass: String = ""      // "iPad", "iPhone", "iPod"
    var screenPixelHeight: Int = 2048 // native pixel height (longest edge)
    var screenScale: Int = 2          // retina scale factor (2x or 3x)
}

extension DeviceInfo {
    /// Effective point height = pixels / scale. This is what matters for video.
    var screenPointHeight: Int { screenPixelHeight / screenScale }

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
    var suggestedResolution: ResolutionLimit {
        let pts = screenPointHeight
        if pts <= 750 { return .hd }     // iPhone SE/mini → 720p
        return .fhd                       // Everything else → 1080p
    }

    /// Short screen description for the status bar.
    var screenDescription: String {
        "\(screenPixelHeight / screenScale)p"
    }

    /// Human-readable device description.
    var displayName: String {
        if !deviceName.isEmpty && deviceName != "iOS Device" {
            return deviceName
        }
        if !productType.isEmpty {
            return "\(deviceClass.isEmpty ? "iOS" : deviceClass) (\(productType))"
        }
        return String(udid.prefix(12)) + "..."
    }
}

enum DeviceError: LocalizedError {
    case notFound

    var errorDescription: String? {
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
    info.deviceClass = readDeviceValue(device, key: "DeviceClass") ?? ""

    // Map product types to screen specs
    let (pixels, scale) = screenSpecsForProduct(info.productType, deviceClass: info.deviceClass)
    info.screenPixelHeight = pixels
    info.screenScale = scale

    return info
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

class DeviceMonitor {
    static let shared = DeviceMonitor()

    var currentDevice: DeviceInfo?
    private var started = false
    private let lock = NSLock()

    func start() {
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

func discoverDevice(timeout: TimeInterval = 5.0) throws -> DeviceInfo {
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
