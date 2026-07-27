import ProjectDescription

let project = Project(
    name: "Octavo",
    packages: [
        .package(path: ".")
    ],
    targets: [
        .target(
            name: "Octavo",
            destinations: .macOS,
            product: .app,
            bundleId: "org.octavo.Octavo",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "Octavo",
                "CFBundleIconName": "Octavo",
                "NSHighResolutionCapable": true,
                "NSPrincipalClass": "NSApplication",
            ]),
            sources: ["Sources/Octavo/**"],
            resources: ["Resources/Octavo.icon"],
            dependencies: [
                .package(product: "SyncEngine"),
                .package(product: "CalibreLibrary"),
                .package(product: "MetadataFetch"),
                .package(product: "KindleFormat"),
            ],
            settings: .settings(base: [
                "ASSETCATALOG_COMPILER_APPICON_NAME": "Octavo"
            ])
        ),
        .target(
            name: "OctavoTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "org.octavo.OctavoTests",
            deploymentTargets: .macOS("26.0"),
            sources: ["Tests/OctavoTests/**"],
            dependencies: [.target(name: "Octavo")]
        ),
        .target(
            name: "MTPKitTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "org.octavo.MTPKitTests",
            deploymentTargets: .macOS("26.0"),
            sources: ["Tests/MTPKitTests/**"],
            dependencies: [.package(product: "MTPKit")]
        ),
        .target(
            name: "CalibreLibraryTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "org.octavo.CalibreLibraryTests",
            deploymentTargets: .macOS("26.0"),
            sources: ["Tests/CalibreLibraryTests/**"],
            dependencies: [.package(product: "CalibreLibrary")]
        ),
        .target(
            name: "SyncEngineTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "org.octavo.SyncEngineTests",
            deploymentTargets: .macOS("26.0"),
            sources: ["Tests/SyncEngineTests/**"],
            dependencies: [.package(product: "SyncEngine")]
        ),
        .target(
            name: "MetadataFetchTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "org.octavo.MetadataFetchTests",
            deploymentTargets: .macOS("26.0"),
            sources: ["Tests/MetadataFetchTests/**"],
            dependencies: [.package(product: "MetadataFetch")]
        ),
        .target(
            name: "KindleFormatTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "org.octavo.KindleFormatTests",
            deploymentTargets: .macOS("26.0"),
            sources: ["Tests/KindleFormatTests/**"],
            dependencies: [.package(product: "KindleFormat")]
        ),
    ]
)
