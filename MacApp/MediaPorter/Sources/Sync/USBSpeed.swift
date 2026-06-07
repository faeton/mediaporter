// USB bus-speed detection via public IOKit. Read-only registry walk —
// no entitlements, no admin prompt, no kext. Used to surface a "your
// cable is the bottleneck" hint when a USB-3-capable iPhone/iPad
// negotiates at USB 2 High Speed (480 Mbps).

import Foundation
import IOKit
import IOKit.usb

/// Current negotiated USB bus speed in Mbps for a connected Apple device.
///
/// `serial` is matched against the USB Serial Number, case-insensitive,
/// with hyphens stripped (iPhone 15+ encode UDID-like serials with a
/// dash, USB Serial Number sometimes does and sometimes doesn't). When
/// only one iPhone/iPad is plugged in we return its speed even without
/// a serial match so the hint still shows for the common single-device
/// case.
///
/// We filter the IOKit walk to ProductString "iPhone" / "iPad" because a
/// typical Mac dev rig has 2-4 Apple USB devices (Magic Keyboard, Mouse,
/// AirPods case, Studio Display); without the filter `appleCount > 1`
/// pushed every lookup into strict-serial-match, which silently failed
/// for the modern dashed-UDID format and gave an empty suffix in the
/// connection pill.
///
/// Returns nil if no iPhone/iPad USB device is present or the registry
/// walk fails. nil here is the signal "device isn't on USB" — caller can
/// fall back to a Wi-Fi label. Speeds map per Apple's IOUSBHostFamily:
/// 2 = USB 2 (480 Mbps), 3 = USB 3 (5 Gbps), 4 = USB 3.1 (10 Gbps),
/// 5 = USB 3.2 (20 Gbps).
public func queryUSBNegotiatedSpeedMbps(serial: String? = nil) -> Int? {
    guard let matching = IOServiceMatching("IOUSBHostDevice") else { return nil }
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
        return nil
    }
    defer { IOObjectRelease(iter) }

    let wanted = serial?.lowercased().replacingOccurrences(of: "-", with: "")
    var firstMobileSpeed: Int? = nil
    var mobileCount = 0

    while case let entry = IOIteratorNext(iter), entry != 0 {
        defer { IOObjectRelease(entry) }
        guard let vid = readUInt(entry, "idVendor"), vid == 0x05AC else { continue }
        guard isAppleMobileDevice(entry) else { continue }
        mobileCount += 1
        guard let speedCode = readUInt(entry, "Device Speed") else { continue }
        let mbps = mbpsForUSBSpeedCode(speedCode)
        if firstMobileSpeed == nil { firstMobileSpeed = mbps }
        if let want = wanted, let sn = readString(entry, "USB Serial Number") {
            let norm = sn.lowercased().replacingOccurrences(of: "-", with: "")
            if norm == want || want.contains(norm) || norm.contains(want) {
                return mbps
            }
        }
    }
    return mobileCount == 1 ? firstMobileSpeed : nil
}


/// Heuristic: is this Apple USB entry an iPhone or iPad (not a keyboard,
/// mouse, AirPods case, or Studio Display)? Reads `kUSBProductString` /
/// `USB Product Name` for a substring match; falls back to known iPhone /
/// iPad USB PID ranges if the string property is missing (rare).
private func isAppleMobileDevice(_ entry: io_registry_entry_t) -> Bool {
    if let name = readString(entry, "USB Product Name")
        ?? readString(entry, "kUSBProductString") {
        let lower = name.lowercased()
        if lower.contains("iphone") || lower.contains("ipad") || lower.contains("ipod") {
            return true
        }
    }
    if let pid = readUInt(entry, "idProduct") {
        // Apple iPhone/iPad PID range. iPods/iPhones live around 0x1290-0x12AB;
        // iPads share that band. Loose match is fine — we already gated VID.
        if pid >= 0x1290 && pid <= 0x12FF { return true }
    }
    return false
}

/// Maximum USB negotiation this product is physically capable of, in Mbps.
/// "Capable" here means with a cable that doesn't limit you — base iPhone 15
/// is USB-C but the silicon only does USB 2, so 480 is the cap regardless
/// of cable.
public func usbMaxCapabilityMbps(productType: String) -> Int {
    let pt = productType.lowercased()

    // Thunderbolt / USB 4 — iPad Pro M1/M2/M4. Theoretical 40 Gbps; in
    // practice the over-the-wire mass-storage throughput is still gated by
    // USB 3.x backend, but for our UI it's "definitely not USB 2".
    let thunderbolt: Set<String> = [
        "ipad13,4", "ipad13,5", "ipad13,6", "ipad13,7",   // iPad Pro 11" M1
        "ipad13,8", "ipad13,9", "ipad13,10", "ipad13,11", // iPad Pro 12.9" M1
        "ipad14,3", "ipad14,4",                            // iPad Pro 11" M2
        "ipad14,5", "ipad14,6",                            // iPad Pro 12.9" M2
        "ipad16,3", "ipad16,4", "ipad16,5", "ipad16,6",    // iPad Pro M4
    ]
    if thunderbolt.contains(pt) { return 40000 }

    // USB 3.1 Gen 2 — 10 Gbps. iPad Air 4/5/M2 and iPhone 15/16 Pro line.
    let usb3_10g: Set<String> = [
        "iphone16,1", "iphone16,2",   // iPhone 15 Pro / Pro Max
        "iphone17,1", "iphone17,2",   // iPhone 16 Pro / Pro Max
        "ipad13,1", "ipad13,2",       // iPad Air 4
        "ipad13,16", "ipad13,17",     // iPad Air 5
        "ipad14,8", "ipad14,9", "ipad14,10", "ipad14,11", // iPad Air M2
    ]
    if usb3_10g.contains(pt) { return 10000 }

    // USB 3.1 Gen 1 — 5 Gbps. iPad mini 6.
    let usb3_5g: Set<String> = [
        "ipad14,1", "ipad14,2",
    ]
    if usb3_5g.contains(pt) { return 5000 }

    // Everything else: USB 2 (480 Mbps). Includes USB-C-but-USB-2 devices
    // like iPhone 15/16 base/Plus and iPad 10th gen — the cable can't help.
    return 480
}

/// Short human label for a Mbps value. "USB 2", "USB 3 (5 Gbps)", etc.
public func usbSpeedLabel(mbps: Int) -> String {
    switch mbps {
    case ..<480: return "USB 1"
    case 480: return "USB 2"
    case 5000: return "USB 3 (5 Gbps)"
    case 10000: return "USB 3 (10 Gbps)"
    case 20000: return "USB 3 (20 Gbps)"
    case 40000: return "USB 4 / Thunderbolt"
    default: return "\(mbps) Mbps"
    }
}

// MARK: - Private helpers

private func mbpsForUSBSpeedCode(_ code: Int) -> Int {
    switch code {
    case 0: return 1      // Low Speed 1.5 Mbps
    case 1: return 12     // Full Speed 12 Mbps
    case 2: return 480    // High Speed (USB 2)
    case 3: return 5000   // Super Speed (USB 3.0)
    case 4: return 10000  // SuperSpeed+ (USB 3.1)
    case 5: return 20000  // SuperSpeed+ 20G
    default: return 0
    }
}

private func readUInt(_ entry: io_registry_entry_t, _ key: String) -> Int? {
    guard let raw = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0) else {
        return nil
    }
    let ref = raw.takeRetainedValue()
    guard CFGetTypeID(ref) == CFNumberGetTypeID() else { return nil }
    var v: Int64 = 0
    CFNumberGetValue((ref as! CFNumber), .sInt64Type, &v)
    return Int(v)
}

private func readString(_ entry: io_registry_entry_t, _ key: String) -> String? {
    guard let raw = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0) else {
        return nil
    }
    let ref = raw.takeRetainedValue()
    guard CFGetTypeID(ref) == CFStringGetTypeID() else { return nil }
    return (ref as! CFString) as String
}
