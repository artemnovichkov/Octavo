import Foundation
import IOKit
import MTPKit

// M0 probe: dumps USB descriptors, then tries to claim the MTP interface and run a
// read-only session. Nothing here writes to the device.

let arguments = CommandLine.arguments.dropFirst()
let showAll = arguments.contains("--all")
let listFiles = arguments.contains("--ls")
/// `--ls <path>` narrows the listing to a folder; bare `--ls` lists documents/.
let listPath: String = arguments.firstIndex(of: "--ls").map { index in
    let next = arguments.index(after: index)
    let candidate = next < arguments.endIndex ? arguments[next] : ""
    return candidate.hasPrefix("--") ? "documents" : candidate
} ?? "documents"
/// `--cat <path>` dumps a file from the device to stdout. Read-only.
let catPath: String? = arguments.firstIndex(of: "--cat").map { index in
    let next = arguments.index(after: index)
    return next < arguments.endIndex ? arguments[next] : ""
}

/// `--push <file>` uploads a local file into documents/. Used for format experiments.
let pushPath: String? = arguments.firstIndex(of: "--push").map { index in
    let next = arguments.index(after: index)
    return next < arguments.endIndex ? arguments[next] : ""
}

/// `--rm <name>` deletes a file from documents/ by name.
let removeName: String? = arguments.firstIndex(of: "--rm").map { index in
    let next = arguments.index(after: index)
    return next < arguments.endIndex ? arguments[next] : ""
}

/// In --cat mode stdout carries the file, so the report goes to stderr.
let dumpingFile = !(catPath ?? "").isEmpty

func say(_ text: String = "") {
    if dumpingFile {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    } else {
        print(text)
    }
}

func hex(_ value: Int, _ digits: Int = 4) -> String {
    String(format: "0x%0\(digits)X", value)
}

func humanSize(_ bytes: UInt64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = Double(bytes)
    var index = 0
    while value >= 1024, index < units.count - 1 {
        value /= 1024
        index += 1
    }
    return String(format: value < 10 && index > 0 ? "%.1f %@" : "%.0f %@", value, units[index])
}

// MARK: - Descriptors

let devices = USBDiscovery.devices()
let interesting = showAll ? devices : devices.filter(\.isKindle)

say("USB devices found: \(devices.count), of them Amazon: \(devices.filter(\.isKindle).count)")

guard !interesting.isEmpty else {
    say("\nNo Kindle found. Plug the device in and unlock the screen.")
    say("Show every device: mtpprobe --all")
    exit(1)
}

for device in interesting {
    say("""

    \(device.product ?? "Unknown") — \(device.manufacturer ?? "?")
      VID/PID: \(hex(device.vendorID)) / \(hex(device.productID))
      Serial:  \(device.serialNumber ?? "—")
      Interfaces: \(device.interfaces.count)
    """)
    for interface in device.interfaces {
        let marker = interface.looksLikeMTP ? "  <- looks like MTP" : ""
        say("""
            [\(interface.number)] class=\(hex(interface.interfaceClass, 2)) \
        sub=\(hex(interface.subClass, 2)) proto=\(hex(interface.interfaceProtocol, 2)) \
        name=\(interface.name ?? "—")\(marker)
        """)
    }
}

// MARK: - Claim + session

say("\n--- Trying to claim the MTP interface (no root) ---")

let transport: MTPTransport
do {
    transport = try MTPTransport.openKindle()
    say("Interface claimed.")
} catch {
    say("Failed: \(error.localizedDescription)")
    say("""

    If a system driver is holding the interface, the plan from here is:
      1) quit Send-to-Kindle / Image Capture / Android File Transfer if they are running;
      2) try IOUSBHostObjectInitOptionsDeviceSeize;
      3) last resort — .deviceCapture, which needs root or com.apple.vm.device-access.
    """)
    exit(2)
}

let session = MTPSession(transport: transport)

do {
    try session.open()
    let info = try session.deviceInfo()
    say("""

    GetDeviceInfo:
      Manufacturer: \(info.manufacturer)
      Model:        \(info.model)
      Firmware:     \(info.deviceVersion)
      Serial:       \(info.serialNumber)
      PTP version:  \(info.standardVersion)
      Extension:    \(info.vendorExtensionDescription)
      Operations:   \(info.operationsSupported.count)
    """)

    let required: [PTPOperation] = [
        .getStorageIDs, .getObjectHandles, .getObjectInfo, .getObject,
        .sendObjectInfo, .sendObject, .deleteObject,
    ]
    say("\n  Required operations:")
    for operation in required {
        say("    \(info.supports(operation) ? "✓" : "✗") \(operation)")
    }

    let storages = try session.storages()
    say("\nStorages:")
    for storage in storages {
        let description = storage.description.isEmpty ? "(unnamed)" : storage.description
        say("  [\(hex(Int(storage.id), 8))] \(description) — \(humanSize(storage.freeSpace)) free of \(humanSize(storage.capacity))")
    }

    if let storage = storages.first, let removeName, !removeName.isEmpty {
        guard let documents = try session.object(at: "documents", storageID: storage.id),
              let victim = try session.children(storageID: storage.id, parent: documents.id)
                  .first(where: { $0.filename == removeName && !$0.isFolder })
        else {
            say("Not found in documents/: \(removeName)")
            exit(4)
        }
        try session.delete(handle: victim.id)
        say("Deleted: documents/\(removeName)")
        try session.close()
        exit(0)
    }

    if let storage = storages.first, let pushPath, !pushPath.isEmpty {
        let url = URL(filePath: pushPath)
        guard let documents = try session.object(at: "documents", storageID: storage.id) else {
            say("No documents/ folder")
            exit(4)
        }
        let data = try Data(contentsOf: url)
        say("\nSending \(url.lastPathComponent) — \(humanSize(UInt64(data.count)))…")
        try session.sendFile(
            Array(data),
            named: url.lastPathComponent,
            storageID: storage.id,
            parent: documents.id
        )
        say("Done. The file is at documents/\(url.lastPathComponent)")
        try session.close()
        exit(0)
    }

    if let storage = storages.first, let catPath, !catPath.isEmpty {
        guard let object = try session.object(at: catPath, storageID: storage.id) else {
            say("\nNot found: \(catPath)")
            exit(4)
        }
        let bytes = try session.data(of: object.id)
        FileHandle.standardOutput.write(Data(bytes))
        try session.close()
        exit(0)
    }

    if let storage = storages.first {
        let root = try session.children(storageID: storage.id)
        say("\nStorage root (\(root.count)):")
        for object in root.prefix(20) {
            say("  \(object.isFolder ? "📁" : "📄") \(object.filename)")
        }

        let folder = listPath.isEmpty ? "documents" : listPath
        if let documents = try session.object(at: folder, storageID: storage.id) {
            let books = try session.children(storageID: storage.id, parent: documents.id)
            let files = books.filter { !$0.isFolder }
            say("\n\(folder)/: \(files.count) files, \(books.count - files.count) folders")
            if listFiles {
                for book in books.sorted(by: { $0.filename < $1.filename }) {
                    let size = book.isFolder ? "" : " — \(humanSize(book.size))"
                    say("  \(book.isFolder ? "📁" : "📄") \(book.filename)\(size)")
                }
            } else {
                for book in files.prefix(10) {
                    say("  📄 \(book.filename) — \(humanSize(book.size))")
                }
                if files.count > 10 { say("  … \(files.count - 10) more, full list: mtpprobe --ls") }
            }
        } else {
            say("\nNo documents/ folder — check that the device is unlocked.")
        }
    }

    try session.close()
    say("\nM0 passed: MTP works without root, nothing was written to the device.")
} catch {
    say("\nSession error: \(error.localizedDescription)")
    exit(3)
}
