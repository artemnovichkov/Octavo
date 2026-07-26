import Foundation
import Testing
@testable import MTPKit

/// Collects events until `deadline` elapses. The watcher's initial drain reports hardware
/// that is already plugged in, so a connected Kindle produces events immediately.
private func collect(for deadline: Duration, vendorID: Int = amazonVendorID) async -> [USBEvent] {
    let events = USBWatcher.events(vendorID: vendorID)

    let collector = Task { () -> [USBEvent] in
        var seen: [USBEvent] = []
        for await event in events { seen.append(event) }
        return seen
    }
    try? await Task.sleep(for: deadline)
    collector.cancel()
    return await collector.value
}

@Test func watcherReportsAlreadyConnectedKindle() async throws {
    // Bail out silently when no Kindle is attached, like the rest of the suite.
    guard !USBDiscovery.devices().filter(\.isKindle).isEmpty else { return }

    let seen = await collect(for: .milliseconds(500))

    #expect(seen.contains(.deviceAttached))
    // Only when the Kindle is actually in MTP mode — charge-only publishes no such interface.
    let hasMTP = USBDiscovery.devices()
        .filter(\.isKindle)
        .contains { $0.interfaces.contains(where: \.looksLikeMTP) }
    #expect(seen.contains(.mtpReady) == hasMTP)
}

@Test func watcherStaysSilentForAnUnusedVendor() async throws {
    // 0x0001 is not a real vendor here, so nothing should ever match.
    let seen = await collect(for: .milliseconds(300), vendorID: 0x0001)
    #expect(seen.isEmpty)
}

@Test func watcherTearsDownCleanly() async throws {
    // Repeated create/cancel cycles would trip over a double release or a destroyed port.
    for _ in 0..<5 {
        _ = await collect(for: .milliseconds(50))
    }
}
