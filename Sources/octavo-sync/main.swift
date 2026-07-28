import CalibreLibrary
import Foundation
import KindleFormat
import MTPKit
import SyncEngine

// Dry run unless --apply is passed: prints what a sync would do and touches nothing.

let arguments = Array(CommandLine.arguments.dropFirst())
let apply = arguments.contains("--apply")
let skipBackup = arguments.contains("--no-backup")
let showOrphans = arguments.contains("--orphans")

/// Overrides Octavo.app's Conversion setting for this run. Without it the CLI converts to
/// whatever the app is set to, the same way --library defaults to the resolved library.
/// A bad value is fatal rather than ignored: writing the wrong format to the device is not
/// something to fall back from quietly.
let conversionTarget: ConversionTarget = {
    guard let index = arguments.firstIndex(of: "--format") else { return .preferred }
    guard index + 1 < arguments.count,
          let target = ConversionTarget(rawValue: arguments[index + 1].lowercased())
    else {
        print("Unknown format. Use --format azw3 or --format mobi.")
        exit(1)
    }
    return target
}()

/// Same resolution the app uses, so the CLI reports on the library the window is showing.
let libraryRoot: URL? = {
    if let index = arguments.firstIndex(of: "--library"), index + 1 < arguments.count {
        return URL(filePath: arguments[index + 1])
    }
    return LibraryLocation.resolve()
}()

guard let libraryRoot else {
    print("No library. Pass --library <path>, or create one in Octavo.app.")
    exit(1)
}

func humanSize(_ bytes: Int64) -> String {
    let units = ["B", "KB", "MB", "GB"]
    var value = Double(bytes)
    var index = 0
    while value >= 1024, index < units.count - 1 {
        value /= 1024
        index += 1
    }
    return String(format: value < 10 && index > 0 ? "%.1f %@" : "%.0f %@", value, units[index])
}

do {
    let library = try CalibreLibraryStore(root: libraryRoot, readOnly: true)
    let books = try library.books()
    print("Library: \(books.count) books — \(library.root.path(percentEncoded: false))")

    let transport = try MTPTransport.openKindle()
    let session = MTPSession(transport: transport)
    try session.open()
    defer { try? session.close() }

    let engine = try SyncEngine(library: library, session: session)
    engine.conversionTarget = conversionTarget
    print("Device: \(transport.device.product ?? "Kindle") — \(humanSize(Int64(engine.storage.freeSpace))) free")
    print("Conversion target: \(conversionTarget.displayName)")

    let manifest = try engine.loadManifest()
    print("Manifest: \(manifest.entries.count) entries\(manifest.adoptedFromCalibre ? " (adopted from calibre)" : "")")

    let plan = try engine.plan(books: books, manifest: manifest)

    print("\nUp to date: \(plan.upToDate.count)")

    if !plan.send.isEmpty {
        print("\nTo send: \(plan.send.count) — \(humanSize(plan.totalBytes))")
        for item in plan.send {
            let conversion = item.conversion.map { " → \($0.displayName)" } ?? ""
            print("  → \(item.filename) [\(item.reason.rawValue), \(humanSize(item.format.size))\(conversion)]")
        }
    }

    if !plan.unsupported.isEmpty {
        print("\nThe Kindle cannot open these (conversion needed): \(plan.unsupported.count)")
        for book in plan.unsupported {
            let formats = book.formats.map(\.format).joined(separator: ", ")
            print("  ✗ \(book.title) — only has \(formats)")
        }
    }

    if !plan.orphans.isEmpty {
        print("\nOn the device but not from the library: \(plan.orphans.count)")
        if showOrphans {
            for object in plan.orphans.sorted(by: { $0.filename < $1.filename }) {
                print("  ? \(object.filename) — \(humanSize(Int64(object.size)))")
            }
        } else {
            print("  (full list: --orphans; Octavo leaves them alone)")
        }
    }

    guard apply else {
        print("\nThis is a dry run. Nothing was written. For a real sync: octavo-sync --apply")
        exit(0)
    }

    guard !plan.isEmpty else {
        if manifest.adoptedFromCalibre {
            // Persist the adoption so the next run doesn't depend on calibre's file.
            try engine.saveManifest(manifest)
            print("\nNothing to send. calibre's manifest was adopted and saved as \(DeviceManifest.filename).")
        } else {
            print("\nEverything is up to date, nothing to send.")
        }
        exit(0)
    }

    if !skipBackup {
        let backup = SyncEngine.defaultBackupDirectory
        print("\nBacking up documents/ to \(backup.path(percentEncoded: false))")
        try engine.backupDocuments(to: backup) { name, index, total in
            print("  [\(index + 1)/\(total)] \(name)")
        }
    }

    print("\nSending \(plan.send.count) files…")
    let updated = try engine.execute(plan, manifest: manifest) { progress in
        print("  [\(progress.index + 1)/\(progress.total)] \(progress.item.filename) — \(humanSize(progress.item.format.size))")
    }
    print("Done. The manifest holds \(updated.entries.count) books.")
} catch {
    print("Error: \(error.localizedDescription)")
    exit(1)
}
