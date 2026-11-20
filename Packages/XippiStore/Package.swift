// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "XippiStore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "XippiStore", targets: ["XippiStore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.12.0")
    ],
    targets: [
        .target(name: "XippiStore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "XippiStoreTests", dependencies: ["XippiStore"]),
    ],
    swiftLanguageModes: [.v6]
)

// Shared by every target in the repository's packages: the same import rules
// as the app target, and warnings fail the build.
for target in package.targets {
    target.swiftSettings =
        (target.swiftSettings ?? []) + [
            .enableUpcomingFeature("MemberImportVisibility"),
            .treatAllWarnings(as: .error),
        ]
}
