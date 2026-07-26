import Testing
@testable import MTPKit

@Test func containerRoundTrip() throws {
    let original = PTPContainer(command: .getObjectHandles, transactionID: 7, parameters: [0x10001, 0, 0xFFFF_FFFF])
    let (decoded, length) = try PTPContainer.decode(original.encoded)
    #expect(length == original.encoded.count)
    #expect(decoded.type == .command)
    #expect(decoded.code == PTPOperation.getObjectHandles.rawValue)
    #expect(decoded.transactionID == 7)
    #expect(decoded.parameters == [0x10001, 0, 0xFFFF_FFFF])
}
