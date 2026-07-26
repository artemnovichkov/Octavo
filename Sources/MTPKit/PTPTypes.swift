import Foundation

/// Container types of the PTP transaction protocol (PIMA 15740, §2.3).
public enum PTPContainerType: UInt16, Sendable {
    case command = 1
    case data = 2
    case response = 3
    case event = 4
}

public enum PTPOperation: UInt16, Sendable {
    case getDeviceInfo = 0x1001
    case openSession = 0x1002
    case closeSession = 0x1003
    case getStorageIDs = 0x1004
    case getStorageInfo = 0x1005
    case getObjectHandles = 0x1007
    case getObjectInfo = 0x1008
    case getObject = 0x1009
    case deleteObject = 0x100B
    case sendObjectInfo = 0x100C
    case sendObject = 0x100D
    case getPartialObject = 0x101B
    case getObjectPropsSupported = 0x9801
    case getObjectPropValue = 0x9803
    case getObjectPropList = 0x9805
}

public enum PTPResponse: UInt16, Sendable {
    case ok = 0x2001
    case generalError = 0x2002
    case sessionNotOpen = 0x2003
    case operationNotSupported = 0x2005
    case parameterNotSupported = 0x2006
    case incompleteTransfer = 0x2007
    case invalidStorageID = 0x2008
    case invalidObjectHandle = 0x2009
    case storeFull = 0x200C
    case storeReadOnly = 0x200E
    case accessDenied = 0x200F
    case partialDeletion = 0x2012
    case storeNotAvailable = 0x2013
    case invalidParentObject = 0x201A
    case invalidParameter = 0x201D
    case sessionAlreadyOpen = 0x201E
    case transactionCancelled = 0x201F
    case invalidObjectPropCode = 0xA801
}

/// Object format codes. Only the ones the sync engine cares about.
public enum PTPObjectFormat: UInt16, Sendable {
    case undefined = 0x3000
    case association = 0x3001  // folder
    case text = 0x3004
    case html = 0x3005
}

public struct MTPStorage: Sendable, Identifiable {
    public let id: UInt32
    public let description: String
    public let volumeIdentifier: String
    public let capacity: UInt64
    public let freeSpace: UInt64

    public var usedSpace: UInt64 { capacity >= freeSpace ? capacity - freeSpace : 0 }
}

public struct MTPObject: Sendable, Identifiable {
    public let id: UInt32
    public let storageID: UInt32
    public let parentID: UInt32
    public let format: UInt16
    public let size: UInt64
    public let filename: String
    public let modified: Date?

    public var isFolder: Bool { format == PTPObjectFormat.association.rawValue }
}

public struct MTPDeviceInfo: Sendable {
    public let standardVersion: UInt16
    public let vendorExtensionID: UInt32
    public let vendorExtensionDescription: String
    public let operationsSupported: [UInt16]
    public let manufacturer: String
    public let model: String
    public let deviceVersion: String
    public let serialNumber: String

    public func supports(_ operation: PTPOperation) -> Bool {
        operationsSupported.contains(operation.rawValue)
    }
}

public enum MTPError: Error, LocalizedError {
    case deviceNotFound
    case noMTPInterface
    case interfaceBusy(String)
    case endpointsNotFound
    case transferFailed(String)
    case shortTransfer(expected: Int, got: Int)
    case malformedContainer(String)
    case operationFailed(PTPOperation, PTPResponse)
    case unexpectedResponseCode(UInt16)
    case truncatedData

    public var errorDescription: String? {
        switch self {
        case .deviceNotFound:
            return "No Kindle found on USB"
        case .noMTPInterface:
            return "The device has no MTP interface"
        case .interfaceBusy(let detail):
            return "The MTP interface is busy in another process: \(detail)"
        case .endpointsNotFound:
            return "The interface has no bulk endpoints"
        case .transferFailed(let detail):
            return "USB transfer error: \(detail)"
        case .shortTransfer(let expected, let got):
            return "Transferred \(got) bytes instead of \(expected)"
        case .malformedContainer(let detail):
            return "Malformed PTP container: \(detail)"
        case .operationFailed(let op, let code):
            return "The device rejected operation \(op): \(code)"
        case .unexpectedResponseCode(let raw):
            return String(format: "Unknown device response code: 0x%04X", raw)
        case .truncatedData:
            return "The device response was truncated"
        }
    }
}
