import Foundation
import IOKit
import IOKit.serial
import IOKit.usb

/// A serial port found on the system.
public struct SerialPortInfo: Sendable, Hashable, Identifiable {
    /// Callout device path (`/dev/cu.*`).
    public var path: String
    /// USB product name when available, otherwise the device name.
    public var name: String
    public var vendorID: Int?
    public var productID: Int?
    public var id: String { path }

    public init(path: String, name: String, vendorID: Int? = nil, productID: Int? = nil) {
        self.path = path; self.name = name; self.vendorID = vendorID; self.productID = productID
    }

    /// e.g. `usbserial-A1 — FT232R USB UART (0403:6001)`.
    public var displayName: String {
        let short = path.replacingOccurrences(of: "/dev/cu.", with: "")
        var s = short
        if name != short { s += " — \(name)" }
        if let v = vendorID, let p = productID { s += String(format: " (%04X:%04X)", v, p) }
        return s
    }
}

/// Lists serial ports (`/dev/cu.*`) through IOKit (allowed in the sandbox).
public enum SerialPortEnumerator {
    static let ignored = ["Bluetooth-Incoming-Port", "debug-console"]

    public static func ports() -> [SerialPortInfo] {
        guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) as NSMutableDictionary? else { return [] }
        matching[kIOSerialBSDTypeKey] = kIOSerialBSDAllTypes
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [SerialPortInfo] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if let info = info(for: service) { result.append(info) }
        }
        return result.sorted { $0.path < $1.path }
    }

    static func info(for service: io_object_t) -> SerialPortInfo? {
        guard let path = property(service, kIOCalloutDeviceKey) as? String else { return nil }
        if ignored.contains(where: { path.contains($0) }) { return nil }
        let product = searchParents(service, "USB Product Name") as? String
            ?? searchParents(service, kUSBProductString) as? String
        let vendor = (searchParents(service, kUSBVendorID) as? NSNumber)?.intValue
        let productID = (searchParents(service, kUSBProductID) as? NSNumber)?.intValue
        let fallback = path.replacingOccurrences(of: "/dev/cu.", with: "")
        return SerialPortInfo(path: path, name: product ?? fallback, vendorID: vendor, productID: productID)
    }

    static func property(_ service: io_object_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    static func searchParents(_ service: io_object_t, _ key: String) -> Any? {
        IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                        IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
    }
}

/// Calls back on the main queue whenever a serial port appears or disappears.
public final class SerialPortMonitor: @unchecked Sendable {
    private var notifyPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0
    private let onChange: @MainActor @Sendable () -> Void

    public init(onChange: @escaping @MainActor @Sendable () -> Void) {
        self.onChange = onChange
    }

    public func start() {
        guard notifyPort == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let monitor = Unmanaged<SerialPortMonitor>.fromOpaque(refcon).takeUnretainedValue()
            SerialPortMonitor.drain(iterator)
            MainActor.assumeIsolated { monitor.onChange() }
        }
        for (type, iter) in [(kIOFirstMatchNotification, \SerialPortMonitor.addedIterator),
                             (kIOTerminatedNotification, \SerialPortMonitor.removedIterator)] {
            guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) else { continue }
            var it: io_iterator_t = 0
            IOServiceAddMatchingNotification(port, type, matching, callback, refcon, &it)
            SerialPortMonitor.drain(it)   // arm the notification
            self[keyPath: iter] = it
        }
    }

    public func stop() {
        if addedIterator != 0 { IOObjectRelease(addedIterator); addedIterator = 0 }
        if removedIterator != 0 { IOObjectRelease(removedIterator); removedIterator = 0 }
        if let notifyPort { IONotificationPortDestroy(notifyPort) }
        notifyPort = nil
    }

    deinit { stop() }

    static func drain(_ iterator: io_iterator_t) {
        while case let obj = IOIteratorNext(iterator), obj != 0 { IOObjectRelease(obj) }
    }
}
