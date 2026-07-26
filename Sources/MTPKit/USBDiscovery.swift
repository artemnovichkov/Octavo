import Foundation
import IOKit

/// Amazon's USB vendor ID — every Kindle reports it.
public let amazonVendorID = 0x1949

public struct USBInterfaceDescriptorInfo: Sendable {
    public let number: Int
    public let interfaceClass: Int
    public let subClass: Int
    public let interfaceProtocol: Int
    public let name: String?

    /// MTP responders present themselves either as PIMA 15740 still-image devices
    /// or as a vendor-specific interface named "MTP".
    public var looksLikeMTP: Bool {
        if interfaceClass == 6 && subClass == 1 && interfaceProtocol == 1 { return true }
        if interfaceClass == 0xFF, let name, name.uppercased().contains("MTP") { return true }
        return interfaceClass == 0xFF && subClass == 0xFF && interfaceProtocol == 0
    }
}

public struct USBDeviceDescriptorInfo: Sendable {
    public let vendorID: Int
    public let productID: Int
    public let product: String?
    public let manufacturer: String?
    public let serialNumber: String?
    public let interfaces: [USBInterfaceDescriptorInfo]

    public var isKindle: Bool { vendorID == amazonVendorID }
}

/// Read-only walk of the IOKit registry. Nothing here opens or claims a device.
public enum USBDiscovery {
    public static func devices() -> [USBDeviceDescriptorInfo] {
        matchingServices(className: "IOUSBHostDevice").map { service in
            defer { IOObjectRelease(service) }
            return describe(device: service)
        }
    }

    /// Registry entries for USB devices of the given vendor. Caller owns the returned
    /// services and must `IOObjectRelease` them.
    public static func deviceServices(vendorID: Int) -> [io_service_t] {
        matchingServices(className: "IOUSBHostDevice").filter { service in
            let matches = property(service, "idVendor").flatMap { ($0 as? NSNumber)?.intValue } == vendorID
            if !matches { IOObjectRelease(service) }
            return matches
        }
    }

    static func describe(device service: io_service_t) -> USBDeviceDescriptorInfo {
        USBDeviceDescriptorInfo(
            vendorID: intProperty(service, "idVendor") ?? 0,
            productID: intProperty(service, "idProduct") ?? 0,
            product: stringProperty(service, "USB Product Name") ?? stringProperty(service, "kUSBProductString"),
            manufacturer: stringProperty(service, "USB Vendor Name"),
            serialNumber: stringProperty(service, "USB Serial Number"),
            interfaces: interfaceServices(of: service).map { interface in
                defer { IOObjectRelease(interface) }
                return describe(interface: interface)
            }
        )
    }

    static func describe(interface service: io_service_t) -> USBInterfaceDescriptorInfo {
        USBInterfaceDescriptorInfo(
            number: intProperty(service, "bInterfaceNumber") ?? -1,
            interfaceClass: intProperty(service, "bInterfaceClass") ?? -1,
            subClass: intProperty(service, "bInterfaceSubClass") ?? -1,
            interfaceProtocol: intProperty(service, "bInterfaceProtocol") ?? -1,
            name: stringProperty(service, "USB Interface Name")
        )
    }

    /// Child `IOUSBHostInterface` entries of a device. Caller owns the returned services.
    public static func interfaceServices(of device: io_service_t) -> [io_service_t] {
        var iterator: io_iterator_t = 0
        let options = IOOptionBits(kIORegistryIterateRecursively)
        guard IORegistryEntryCreateIterator(device, kIOServicePlane, options, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var result: [io_service_t] = []
        while case let child = IOIteratorNext(iterator), child != IO_OBJECT_NULL {
            if IOObjectConformsTo(child, "IOUSBHostInterface") != 0 {
                result.append(child)
            } else {
                IOObjectRelease(child)
            }
        }
        return result
    }

    /// The registry entry name of whichever driver currently holds the interface, if any.
    /// An unclaimed interface is what lets us open it without root.
    public static func attachedDriver(of interface: io_service_t) -> String? {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(interface, kIOServicePlane, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        while case let child = IOIteratorNext(iterator), child != IO_OBJECT_NULL {
            defer { IOObjectRelease(child) }
            var name = [CChar](repeating: 0, count: 128)
            if IORegistryEntryGetName(child, &name) == KERN_SUCCESS {
                return String(cString: name)
            }
        }
        return nil
    }

    static func matchingServices(className: String) -> [io_service_t] {
        guard let matching = IOServiceMatching(className) else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var result: [io_service_t] = []
        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            result.append(service)
        }
        return result
    }

    static func property(_ service: io_service_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    static func intProperty(_ service: io_service_t, _ key: String) -> Int? {
        (property(service, key) as? NSNumber)?.intValue
    }

    static func stringProperty(_ service: io_service_t, _ key: String) -> String? {
        property(service, key) as? String
    }
}
