// swift-tools-version:6.0
import PackageDescription

// Private libraries are weak-linked: a missing/renamed library on a future macOS makes one sensor
// unavailable instead of failing app launch (ARCHITECTURE §1). ld applies -syslibroot to absolute -F
// paths, so the private framework resolves inside the SDK. swiftc (the link driver) rejects the
// ld-only `-weak-l`/`-weak_framework` options, so they are forwarded with -Xlinker.
let privateLinks: [LinkerSetting] = [
    .unsafeFlags([
        "-F/System/Library/PrivateFrameworks",
        "-Xlinker", "-weak-lIOReport",
        "-Xlinker", "-weak_framework", "-Xlinker", "NetworkStatistics",
    ]),
]

let package = Package(
    name: "MonitorCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MonitorModel", targets: ["MonitorModel"]),
        .library(name: "MonitorLive", targets: ["MonitorLive"]),
        .library(name: "MonitorRuntime", targets: ["MonitorRuntime"]),
        .library(name: "MonitorScreens", targets: ["MonitorScreens"]),
        .library(name: "MonitorUIKit", targets: ["MonitorUIKit"]),
        .executable(name: "telltale-render", targets: ["telltale-render"]),
        .executable(name: "telltale-probe", targets: ["telltale-probe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        // C: private declarations (weak) + SMC shim.
        .target(name: "CPrivate", linkerSettings: privateLinks),

        // Pure Foundation: all shared value types + protocols (locked, ARCHITECTURE §5).
        .target(name: "MonitorModel"),

        .target(name: "MonitorLive", dependencies: ["MonitorModel"]),
        .target(name: "MonitorEngine", dependencies: ["MonitorModel"]),
        .target(
            name: "MonitorSensors",
            dependencies: ["MonitorModel", "CPrivate"],
            resources: [.process("SoC/Resources"), .process("Thermal/Resources")],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
        .target(
            name: "MonitorStore",
            dependencies: ["MonitorModel", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(name: "MonitorUIKit", dependencies: ["MonitorModel"]),
        // Test-support library (imports Testing): assertSnapshot. Never linked by the app.
        .target(name: "MonitorSnapshotTesting", dependencies: ["MonitorUIKit", "SnapshotProcessSetup"]),
        // ObjC, test-only: image constructor sets AppleFontSmoothing = 0 before any test lays out text.
        .target(name: "SnapshotProcessSetup", linkerSettings: [.linkedFramework("Foundation")]),
        .target(name: "MonitorMocks", dependencies: ["MonitorModel"]),
        .target(
            name: "MonitorScreens",
            dependencies: ["MonitorModel", "MonitorLive", "MonitorUIKit", "MonitorMocks"]
        ),
        .target(
            name: "MonitorRuntime",
            dependencies: [
                "MonitorModel", "MonitorLive", "MonitorEngine", "MonitorSensors", "MonitorStore", "MonitorMocks",
            ]
        ),
        .executableTarget(
            name: "telltale-render",
            dependencies: ["MonitorScreens", "MonitorUIKit", "MonitorMocks", "MonitorLive"]
        ),
        .executableTarget(
            name: "telltale-probe",
            dependencies: ["MonitorModel", "MonitorEngine", "MonitorSensors", "MonitorStore"]
        ),

        // Tests
        .testTarget(name: "MonitorModelTests", dependencies: ["MonitorModel"]),
        .testTarget(name: "MonitorLiveTests", dependencies: ["MonitorLive", "MonitorModel"]),
        .testTarget(
            name: "MonitorEngineTests",
            dependencies: ["MonitorEngine", "MonitorModel"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "MonitorStoreTests", dependencies: ["MonitorStore", "MonitorModel"], exclude: ["Golden"]),
        .testTarget(
            name: "MonitorUIKitTests",
            dependencies: ["MonitorUIKit", "MonitorModel", "MonitorSnapshotTesting"],
            exclude: ["__Snapshots__"]
        ),
        .testTarget(
            name: "MonitorScreensTests",
            dependencies: [
                "MonitorScreens", "MonitorUIKit", "MonitorLive", "MonitorMocks", "MonitorModel", "MonitorSnapshotTesting",
            ],
            exclude: ["__Snapshots__"]
        ),
        .testTarget(
            name: "MonitorSensorsTests",
            dependencies: ["MonitorSensors", "MonitorModel"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "MonitorMocksTests", dependencies: ["MonitorMocks", "MonitorModel"]),
        .testTarget(
            name: "MonitorRuntimeTests",
            dependencies: ["MonitorRuntime", "MonitorModel", "MonitorMocks", "MonitorStore", "MonitorEngine"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
