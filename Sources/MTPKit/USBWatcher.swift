import Foundation
import IOKit

/// What the IOKit registry says happened to a Kindle on the bus.
public enum USBEvent: Sendable, Equatable {
    /// A device of the watched vendor was published. MTP may not be up yet — the Kindle
    /// exposes no MTP interface while it is charge-only or the screen is locked.
    case deviceAttached
    /// An interface that `looksLikeMTP` finished matching, so its drivers have started.
    /// This is the moment `MTPTransport.claim` can actually succeed.
    case mtpReady
    /// A device or one of its interfaces was terminated.
    case detached
}

/// Live attach/detach notifications, the counterpart to `USBDiscovery`'s one-shot scans.
public enum USBWatcher {
    /// Events for devices of `vendorID`. The initial arming drain reports hardware that is
    /// already plugged in, so a consumer only needs this one path — there is no separate
    /// "check on launch" step.
    ///
    /// IOKit registrations are torn down when the consuming task is cancelled.
    public static func events(vendorID: Int = amazonVendorID) -> AsyncStream<USBEvent> {
        // Unbounded: events are rare, and dropping a `.detached` is the one loss a
        // consumer cannot recover from.
        AsyncStream(USBEvent.self, bufferingPolicy: .unbounded) { continuation in
            let context = Context(continuation: continuation, vendorID: vendorID)
            context.queue.async { context.start() }
            continuation.onTermination = { _ in
                // The block retains `context`, so it outlives the release inside stop().
                context.queue.async { context.stop() }
            }
        }
    }

    /// Every member is touched only on `queue`, which is also the notification port's
    /// delivery queue — hence the unchecked conformance and the absence of any lock.
    final class Context: @unchecked Sendable {
        let queue = DispatchQueue(label: "org.octavo.usb.watcher")
        let continuation: AsyncStream<USBEvent>.Continuation
        let vendorID: Int

        private var port: IONotificationPortRef?
        private var iterators: [io_iterator_t] = []
        private var refcon: UnsafeMutableRawPointer?

        init(continuation: AsyncStream<USBEvent>.Continuation, vendorID: Int) {
            self.continuation = continuation
            self.vendorID = vendorID
        }

        func start() {
            guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
                continuation.finish()
                return
            }
            self.port = port
            // A dispatch queue rather than a run loop source: MTPKit has to keep working in
            // mtpprobe and octavo-sync, neither of which runs a run loop.
            IONotificationPortSetDispatchQueue(port, queue)

            // One retain, balanced by exactly one release in stop().
            let refcon = Unmanaged.passRetained(self).toOpaque()
            self.refcon = refcon

            // Terminations are armed first and their drains discarded, so the matched
            // drains below are the only thing that reports already-connected hardware.
            for className in ["IOUSBHostDevice", "IOUSBHostInterface"] {
                if let iterator = add(kIOTerminatedNotification, className, usbWatcherTerminated, refcon) {
                    drainDiscarding(iterator)
                }
            }
            if let iterator = add(kIOMatchedNotification, "IOUSBHostDevice", usbWatcherDeviceMatched, refcon) {
                deviceMatched(iterator)
            }
            if let iterator = add(kIOMatchedNotification, "IOUSBHostInterface", usbWatcherInterfaceMatched, refcon) {
                interfaceMatched(iterator)
            }
        }

        func stop() {
            iterators.forEach { IOObjectRelease($0) }
            iterators = []
            if let port { IONotificationPortDestroy(port) }
            port = nil
            if let refcon { Unmanaged<Context>.fromOpaque(refcon).release() }
            refcon = nil
        }

        /// Interface entries carry `idVendor` just like their parent device, so both classes
        /// can be property-matched on it. The vendor filter has to live under
        /// `kIOPropertyMatchKey` — `IOUSBHostDevice`/`IOUSBHostInterface` do not implement the
        /// old IOUSBFamily behaviour of honouring `idVendor` at the top level, where it
        /// silently matches nothing. A fresh dictionary per registration: the call consumes a
        /// reference, and reusing one would depend on the importer honouring `cf_consumed`.
        private func add(
            _ type: String,
            _ className: String,
            _ callback: @convention(c) (UnsafeMutableRawPointer?, io_iterator_t) -> Void,
            _ refcon: UnsafeMutableRawPointer
        ) -> io_iterator_t? {
            guard let port, let matching = IOServiceMatching(className) else { return nil }
            (matching as NSMutableDictionary)[kIOPropertyMatchKey] = ["idVendor": vendorID]

            var iterator: io_iterator_t = IO_OBJECT_NULL
            guard IOServiceAddMatchingNotification(port, type, matching, callback, refcon, &iterator)
                    == KERN_SUCCESS
            else { return nil }

            iterators.append(iterator)
            return iterator
        }

        // MARK: - Drains
        //
        // These are what the C callbacks invoke, and also what `start()` calls to arm each
        // iterator. An iterator from IOServiceAddMatchingNotification is not armed until it
        // has been emptied once — skip the drain and the notification never fires.

        func deviceMatched(_ iterator: io_iterator_t) {
            if drain(iterator) { continuation.yield(.deviceAttached) }
        }

        func interfaceMatched(_ iterator: io_iterator_t) {
            var isMTP = false
            while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
                defer { IOObjectRelease(service) }
                if USBDiscovery.describe(interface: service).looksLikeMTP { isMTP = true }
            }
            if isMTP { continuation.yield(.mtpReady) }
        }

        /// Deliberately does not filter on `looksLikeMTP`: a terminating entry's properties
        /// may already be unreadable, and a missed detach is far worse than a spurious one.
        func terminated(_ iterator: io_iterator_t) {
            if drain(iterator) { continuation.yield(.detached) }
        }

        @discardableResult
        private func drain(_ iterator: io_iterator_t) -> Bool {
            var found = false
            while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
                IOObjectRelease(service)
                found = true
            }
            return found
        }

        private func drainDiscarding(_ iterator: io_iterator_t) {
            drain(iterator)
        }
    }
}

// Top-level functions, not global closure constants: a `let` of function type is a global
// variable, which Swift 6 would require to be isolated or `nonisolated(unsafe)`.

private func usbWatcherDeviceMatched(_ refcon: UnsafeMutableRawPointer?, _ iterator: io_iterator_t) {
    guard let refcon else { return }
    Unmanaged<USBWatcher.Context>.fromOpaque(refcon).takeUnretainedValue().deviceMatched(iterator)
}

private func usbWatcherInterfaceMatched(_ refcon: UnsafeMutableRawPointer?, _ iterator: io_iterator_t) {
    guard let refcon else { return }
    Unmanaged<USBWatcher.Context>.fromOpaque(refcon).takeUnretainedValue().interfaceMatched(iterator)
}

private func usbWatcherTerminated(_ refcon: UnsafeMutableRawPointer?, _ iterator: io_iterator_t) {
    guard let refcon else { return }
    Unmanaged<USBWatcher.Context>.fromOpaque(refcon).takeUnretainedValue().terminated(iterator)
}
