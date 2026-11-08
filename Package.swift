// swift-tools-version:6.0
import PackageDescription

// Module graph (DESIGN.md v5.4, docs/BUILD-PLAN.md):
//   IMCore <- IMStore <- IMPolicy, IMSend, IMUI <- IMForeground <- IMBridge <- IMessageAgent
//   imessage (CLI) depends on IMCore only.
// IMTestSupport holds fakes for IMCore protocols and fixture paths. Only test targets use it.
let package = Package(
    name: "imessage-agent",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "imessage", targets: ["imessage"]),
        .executable(name: "IMessageAgent", targets: ["IMessageAgent"]),
    ],
    targets: [
        .target(name: "IMCore"),
        .target(
            name: "IMStore",
            dependencies: ["IMCore"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(name: "IMPolicy", dependencies: ["IMCore", "IMStore"]),
        .target(name: "IMSend", dependencies: ["IMCore", "IMStore"]),
        .target(name: "IMUI", dependencies: ["IMCore", "IMStore"]),
        .target(name: "IMForeground", dependencies: ["IMCore", "IMStore", "IMPolicy", "IMSend", "IMUI"]),
        .target(
            name: "IMBridge",
            dependencies: ["IMCore", "IMStore", "IMPolicy", "IMSend", "IMUI", "IMForeground"]
        ),
        .executableTarget(name: "IMessageAgent", dependencies: ["IMBridge"]),
        .executableTarget(name: "imessage", dependencies: ["IMCore"]),

        .target(name: "IMTestSupport", dependencies: ["IMCore"], path: "Tests/IMTestSupport"),
        .testTarget(name: "IMCoreTests", dependencies: ["IMCore", "IMTestSupport"]),
        .testTarget(name: "IMStoreTests", dependencies: ["IMStore", "IMCore", "IMTestSupport"]),
        .testTarget(name: "IMPolicyTests", dependencies: ["IMPolicy", "IMStore", "IMCore", "IMTestSupport"]),
        .testTarget(name: "IMSendTests", dependencies: ["IMSend", "IMStore", "IMCore", "IMTestSupport"]),
        .testTarget(name: "IMUITests", dependencies: ["IMUI", "IMStore", "IMCore", "IMTestSupport"]),
        .testTarget(
            name: "IMForegroundTests",
            dependencies: ["IMForeground", "IMUI", "IMSend", "IMPolicy", "IMStore", "IMCore", "IMTestSupport"]
        ),
        .testTarget(
            name: "IMBridgeTests",
            dependencies: ["IMBridge", "IMForeground", "IMUI", "IMSend", "IMPolicy", "IMStore", "IMCore", "IMTestSupport"]
        ),
        .testTarget(name: "imessageCLITests", dependencies: ["imessage", "IMCore", "IMTestSupport"]),
    ],
    swiftLanguageModes: [.v5]
)
