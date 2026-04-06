// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZackEyes",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ZackEyes", targets: ["ZackEyes"]),
        .executable(name: "bridge", targets: ["Bridge"]),
    ],
    targets: [
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
            dependencies: ["Shared"],
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
)
