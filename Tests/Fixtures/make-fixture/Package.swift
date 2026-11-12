// swift-tools-version:6.0
import PackageDescription

let package = Package(
  name: "make-fixture",
  platforms: [.macOS(.v14)],
  targets: [
    .target(
      name: "FixtureKit",
      path: "Sources/FixtureKit",
      linkerSettings: [.linkedLibrary("sqlite3")]
    ),
    .executableTarget(
      name: "make-fixture",
      dependencies: ["FixtureKit"],
      path: "Sources/make-fixture"
    ),
    .executableTarget(
      name: "verify-fixture",
      dependencies: ["FixtureKit"],
      path: "Sources/verify-fixture"
    ),
  ],
  swiftLanguageModes: [.v5]
)
