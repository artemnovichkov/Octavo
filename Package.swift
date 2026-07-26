// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Octavo",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MTPKit", targets: ["MTPKit"]),
        .library(name: "CalibreLibrary", targets: ["CalibreLibrary"]),
        .library(name: "SyncEngine", targets: ["SyncEngine"]),
        .library(name: "MetadataFetch", targets: ["MetadataFetch"]),
        .library(name: "KindleFormat", targets: ["KindleFormat"]),
        .executable(name: "Octavo", targets: ["Octavo"]),
        .executable(name: "mtpprobe", targets: ["mtpprobe"]),
        .executable(name: "octavo-sync", targets: ["octavo-sync"]),
        .executable(name: "octavo-convert", targets: ["octavo-convert"]),
    ],
    targets: [
        .target(name: "MTPKit"),
        .target(name: "CalibreLibrary"),
        .target(name: "SyncEngine", dependencies: ["MTPKit", "CalibreLibrary", "KindleFormat"]),
        .target(name: "MetadataFetch"),
        .target(name: "KindleFormat"),
        .executableTarget(name: "Octavo", dependencies: ["SyncEngine", "CalibreLibrary", "MetadataFetch", "KindleFormat"]),
        .executableTarget(name: "mtpprobe", dependencies: ["MTPKit"]),
        .executableTarget(name: "octavo-sync", dependencies: ["SyncEngine"]),
        .executableTarget(name: "octavo-convert", dependencies: ["KindleFormat"]),
        .testTarget(name: "MTPKitTests", dependencies: ["MTPKit"]),
        .testTarget(name: "CalibreLibraryTests", dependencies: ["CalibreLibrary"]),
        .testTarget(name: "SyncEngineTests", dependencies: ["SyncEngine"]),
        .testTarget(name: "MetadataFetchTests", dependencies: ["MetadataFetch"]),
        .testTarget(name: "KindleFormatTests", dependencies: ["KindleFormat"]),
    ]
)
