import Foundation
import IOKit.hid
import QuartzCore

protocol AngleSource: AnyObject {
    func read() -> Double?
}

final class LidSensor: AngleSource {
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var buffer = [UInt8](repeating: 0, count: 8)
    private var hiRes = true
    private var hiResMisses = 0
    private var nextAttempt = 0.0

    init?() {
        guard acquire() else { return nil }
    }

    func read() -> Double? {
        if device == nil {
            let now = CACurrentMediaTime()
            guard now >= nextAttempt else { return nil }
            nextAttempt = now + 1
            guard acquire() else { return nil }
            lifecycle("lid sensor reopened")
        }
        if let angle = readOnce() { return angle }
        lifecycle("lid sensor read failed; will reopen")
        if let device { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
        device = nil
        manager = nil
        return nil
    }

    private func acquire() -> Bool {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: 0x05AC,
            kIOHIDProductIDKey: 0x8104,
            kIOHIDPrimaryUsagePageKey: 0x20,
            kIOHIDPrimaryUsageKey: 0x8A,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>
        else { return false }

        for candidate in devices where IOHIDDeviceOpen(candidate, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess {
            device = candidate
            validateHiRes()
            if readOnce() != nil {
                self.manager = manager
                return true
            }
            IOHIDDeviceClose(candidate, IOOptionBits(kIOHIDOptionsTypeNone))
            device = nil
        }
        return false
    }

    private func validateHiRes() {
        guard let device else { return }
        var b7 = [UInt8](repeating: 0, count: 8), b1 = [UInt8](repeating: 0, count: 8)
        var l7 = CFIndex(8), l1 = CFIndex(8)
        guard IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &b1, &l1) == kIOReturnSuccess, l1 >= 3 else { return }
        let whole = Double(Int(b1[1]) | Int(b1[2] & 1) << 8)
        if IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 7, &b7, &l7) == kIOReturnSuccess, l7 >= 4 {
            let centi = Int(b7[1]) | Int(b7[2]) << 8 | Int(b7[3]) << 16
            hiRes = centi <= 36000 && abs(Double(centi) / 100 - whole) <= 1.5
        } else {
            hiRes = false
        }
        if !hiRes { lifecycle("hi-res angle not available on this Mac; using whole degrees") }
    }

    private func readOnce() -> Double? {
        guard let device else { return nil }
        if hiRes {
            var length = CFIndex(buffer.count)
            if IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 7, &buffer, &length) == kIOReturnSuccess,
               length >= 4 {
                let centi = Int(buffer[1]) | Int(buffer[2]) << 8 | Int(buffer[3]) << 16
                if centi <= 36000 {
                    hiResMisses = 0
                    return Double(centi) / 100
                }
            }
        }
        var length = CFIndex(buffer.count)
        guard IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &buffer, &length) == kIOReturnSuccess,
              length >= 3
        else { return nil }
        if hiRes {
            hiResMisses += 1
            if hiResMisses >= 20 { hiRes = false; lifecycle("hi-res angle unavailable; using whole degrees") }
        }
        return Double(Int(buffer[1]) | Int(buffer[2] & 1) << 8)
    }
}
