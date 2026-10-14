// swift-tools-version: 6.0
import PackageDescription

var remoteProducts: [Product] = [.executable(name: "zackeyes-stream", targets: ["RemoteStream"])]
var remoteTargets: [Target] = [
    .target(name: "RemoteCore", path: "Sources/RemoteCore"),
    .executableTarget(name: "RemoteStream", dependencies: ["RemoteCore"], path: "Sources/RemoteStream"),
    .testTarget(name: "RemoteCoreTests", dependencies: ["RemoteCore"], path: "Tests/RemoteCoreTests"),
]
#if !os(Linux)
    remoteProducts += [
        .executable(name: "ZackEyes", targets: ["ZackEyes"]), .executable(name: "bridge", targets: ["Bridge"]),
    ]
    remoteTargets += [
        // --- Libraries (testable) ---
        .target(
            name: "Shared",
            path: "Sources/Shared"
        ),
        .target(
            name: "BridgeLib",
            dependencies: ["Shared"],
            path: "Sources/BridgeLib"
        ),
        .target(
            name: "AppLib",
            dependencies: ["Shared", "RemoteCore"],
            path: "Sources/AppLib",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        // --- Executables (thin entry points) ---
        .executableTarget(
            name: "ZackEyes",
            dependencies: ["AppLib"],
            path: "Sources/ZackEyes"
        ),
        .executableTarget(
            name: "Bridge",
            dependencies: ["BridgeLib"],
            path: "Sources/Bridge"
        ),
        // --- Tests (depend on libraries, not executables) ---
        .testTarget(
            name: "SharedTests",
            dependencies: ["Shared"],
            path: "Tests/SharedTests"
        ),
        .testTarget(
            name: "BridgeLibTests",
            dependencies: ["BridgeLib"],
            path: "Tests/BridgeLibTests"
        ),
        .testTarget(
            name: "AppLibTests",
            dependencies: ["AppLib"],
            path: "Tests/AppLibTests"
        ),

    ]
#endif

let package = Package(
    name: "ZackEyes",
    platforms: [.macOS(.v14)],
    products: remoteProducts,
    targets: remoteTargets
)
