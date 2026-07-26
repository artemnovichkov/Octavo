import Foundation
import IOKit
import IOUSBHost

/// Owns the claimed USB interface and moves raw bytes over its bulk pipes.
/// Not thread-safe: drive it from a single actor or queue.
public final class MTPTransport {
    public struct Endpoints {
        let bulkIn: IOUSBHostPipe
        let bulkOut: IOUSBHostPipe
        let maxPacketSize: Int
    }

    private let interface: IOUSBHostInterface
    private let endpoints: Endpoints
    private let queue: DispatchQueue
    private var isInvalidated = false

    /// Bulk reads are issued into a buffer of this size; the device may answer with less.
    public static let readBufferSize = 512 * 1024
    public static let defaultTimeout: TimeInterval = 10

    public let device: USBDeviceDescriptorInfo

    private init(interface: IOUSBHostInterface, endpoints: Endpoints, device: USBDeviceDescriptorInfo, queue: DispatchQueue) {
        self.interface = interface
        self.endpoints = endpoints
        self.device = device
        self.queue = queue
    }

    deinit {
        if !isInvalidated { interface.destroy() }
    }

    /// Releases the claimed interface. Idempotent, so surprise removal — where the caller
    /// tears the transport down while `deinit` is still pending — cannot destroy twice.
    public func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        interface.destroy()
    }

    /// Finds the first Kindle exposing an MTP interface and claims it.
    public static func openKindle() throws -> MTPTransport {
        let services = USBDiscovery.deviceServices(vendorID: amazonVendorID)
        defer { services.forEach { IOObjectRelease($0) } }
        guard !services.isEmpty else { throw MTPError.deviceNotFound }

        var lastError: Error = MTPError.noMTPInterface
        for service in services {
            do {
                return try open(deviceService: service)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    public static func open(deviceService: io_service_t) throws -> MTPTransport {
        let description = USBDiscovery.describe(device: deviceService)
        let interfaceServices = USBDiscovery.interfaceServices(of: deviceService)
        defer { interfaceServices.forEach { IOObjectRelease($0) } }

        let candidates = interfaceServices.filter { USBDiscovery.describe(interface: $0).looksLikeMTP }
        guard !candidates.isEmpty else { throw MTPError.noMTPInterface }

        var lastError: Error = MTPError.noMTPInterface
        for service in candidates {
            do {
                return try claim(interfaceService: service, device: description)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    static func claim(interfaceService: io_service_t, device: USBDeviceDescriptorInfo) throws -> MTPTransport {
        let queue = DispatchQueue(label: "org.octavo.mtp.transport")
        let interface: IOUSBHostInterface
        do {
            interface = try IOUSBHostInterface(
                __ioService: interfaceService,
                options: [],
                queue: queue,
                interestHandler: nil
            )
        } catch {
            let holder = USBDiscovery.attachedDriver(of: interfaceService) ?? "unknown driver"
            throw MTPError.interfaceBusy("\(holder) — \(error.localizedDescription)")
        }

        do {
            let endpoints = try discoverEndpoints(of: interface)
            return MTPTransport(interface: interface, endpoints: endpoints, device: device, queue: queue)
        } catch {
            interface.destroy()
            throw error
        }
    }

    static func discoverEndpoints(of interface: IOUSBHostInterface) throws -> Endpoints {
        let configuration = interface.configurationDescriptor
        let interfaceDescriptor = interface.interfaceDescriptor

        var bulkIn: IOUSBHostPipe?
        var bulkOut: IOUSBHostPipe?
        var maxPacketSize = 512

        var current: UnsafePointer<IOUSBDescriptorHeader>?
        while let endpoint = IOUSBGetNextEndpointDescriptor(configuration, interfaceDescriptor, current) {
            current = UnsafeRawPointer(endpoint).assumingMemoryBound(to: IOUSBDescriptorHeader.self)

            let attributes = Int(endpoint.pointee.bmAttributes) & 0x03
            let address = Int(endpoint.pointee.bEndpointAddress)
            let isInput = address & 0x80 != 0
            guard attributes == 2 else { continue }  // bulk only

            let pipe = try? interface.copyPipe(withAddress: address)
            guard let pipe else { continue }
            maxPacketSize = max(maxPacketSize, Int(endpoint.pointee.wMaxPacketSize))
            if isInput { bulkIn = bulkIn ?? pipe } else { bulkOut = bulkOut ?? pipe }
        }

        guard let bulkIn, let bulkOut else { throw MTPError.endpointsNotFound }
        return Endpoints(bulkIn: bulkIn, bulkOut: bulkOut, maxPacketSize: maxPacketSize)
    }

    // MARK: - Raw transfers

    public func write(_ bytes: [UInt8], timeout: TimeInterval = defaultTimeout) throws {
        guard !isInvalidated else { throw MTPError.transferFailed("the interface is already closed") }
        guard !bytes.isEmpty else { return }
        var sent = 0
        while sent < bytes.count {
            let chunk = Array(bytes[sent..<min(sent + Self.readBufferSize, bytes.count)])
            let buffer = NSMutableData(bytes: chunk, length: chunk.count)
            var transferred: Int = 0
            do {
                try endpoints.bulkOut.__sendIORequest(
                    with: buffer,
                    bytesTransferred: &transferred,
                    completionTimeout: timeout
                )
            } catch {
                throw MTPError.transferFailed(error.localizedDescription)
            }
            guard transferred > 0 else { throw MTPError.shortTransfer(expected: chunk.count, got: transferred) }
            sent += transferred
        }

        // A transfer that is an exact multiple of the packet size needs a terminating
        // zero-length packet so the responder knows the phase ended.
        if bytes.count % endpoints.maxPacketSize == 0 {
            var transferred: Int = 0
            try? endpoints.bulkOut.__sendIORequest(with: nil, bytesTransferred: &transferred, completionTimeout: timeout)
        }
    }

    /// One bulk read. Returns whatever the device sent, up to `capacity` bytes.
    public func read(capacity: Int = readBufferSize, timeout: TimeInterval = defaultTimeout) throws -> [UInt8] {
        guard !isInvalidated else { throw MTPError.transferFailed("the interface is already closed") }
        let buffer = NSMutableData(length: capacity) ?? NSMutableData()
        var transferred: Int = 0
        do {
            try endpoints.bulkIn.__sendIORequest(
                with: buffer,
                bytesTransferred: &transferred,
                completionTimeout: timeout
            )
        } catch {
            throw MTPError.transferFailed(error.localizedDescription)
        }
        let pointer = buffer.bytes.assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: pointer, count: min(transferred, capacity)))
    }
}
