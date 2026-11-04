import Foundation
import IOKit

public struct PortInfo: Identifiable, Hashable, Sendable {
    public enum Kind: Int, Sendable { case demo, usb, other, system }

    public var id: String { path }
    public let path: String
    public let name: String
    public let detail: String
    public let kind: Kind

    public init(path: String, name: String, detail: String, kind: Kind) {
        self.path = path
        self.name = name
        self.detail = detail
        self.kind = kind
    }

    public var menuTitle: String { detail.isEmpty ? name : "\(name)  ·  \(detail)" }
}

/// 列出系统串口，并在设备插拔时通知。回调都在主队列上。
public final class PortScanner: @unchecked Sendable {
    public var onChange: (([PortInfo]) -> Void)?

    private var notifyPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0
    private var pending: DispatchWorkItem?

    public init() {}

    public func start() {
        let port = IONotificationPortCreate(kIOMainPortDefault)
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, .main)

        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let scanner = Unmanaged<PortScanner>.fromOpaque(refcon).takeUnretainedValue()
            PortScanner.drain(iterator)
            scanner.scheduleRescan()
        }
        IOServiceAddMatchingNotification(port, kIOMatchedNotification, IOServiceMatching("IOSerialBSDClient"),
                                         callback, context, &addedIterator)
        IOServiceAddMatchingNotification(port, kIOTerminatedNotification, IOServiceMatching("IOSerialBSDClient"),
                                         callback, context, &removedIterator)
        Self.drain(addedIterator)
        Self.drain(removedIterator)
        onChange?(Self.scan())
    }

    private func scheduleRescan() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.onChange?(Self.scan())
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private static func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
        }
    }

    public static func scan() -> [PortInfo] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOSerialBSDClient"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var result: [PortInfo] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let path = IORegistryEntryCreateCFProperty(service, "IOCalloutDevice" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String else { continue }
            let name = URL(fileURLWithPath: path).lastPathComponent
            let product = usbString(service, keys: ["USB Product Name", "kUSBProductString"])
            let vendor = usbString(service, keys: ["USB Vendor Name", "kUSBVendorString"])
            let lower = name.lowercased()
            let kind: PortInfo.Kind
            if lower.contains("bluetooth") || lower.contains("debug-console") || lower.contains("wlan") {
                kind = .system
            } else if product != nil || lower.contains("usb") || lower.contains("wch") || lower.contains("slab") {
                kind = .usb
            } else {
                kind = .other
            }
            let detail: String
            switch (vendor, product) {
            case let (v?, p?): detail = p.localizedCaseInsensitiveContains(v) ? p : "\(v) \(p)"
            case let (nil, p?): detail = p
            default: detail = kind == .system ? "系统端口" : ""
            }
            result.append(PortInfo(path: path, name: name, detail: detail, kind: kind))
        }
        return result.sorted { ($0.kind.rawValue, $0.name) < ($1.kind.rawValue, $1.name) }
    }

    private static func usbString(_ service: io_object_t, keys: [String]) -> String? {
        let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        for key in keys {
            if let value = IORegistryEntrySearchCFProperty(service, "IOService", key as CFString, kCFAllocatorDefault, options) as? String,
               !value.isEmpty {
                return value
            }
        }
        return nil
    }
}
