// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "XMPPCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "XMPPCore", targets: ["XMPPCore"]),
        .library(name: "XMPPTestSupport", targets: ["XMPPTestSupport"]),
    ],
    targets: [
        .target(name: "XMPPCore"),
        .target(name: "XMPPTestSupport", dependencies: ["XMPPCore"]),
        .testTarget(
            name: "XMPPCoreTests",
            dependencies: ["XMPPCore", "XMPPTestSupport"],
            resources: [.copy("Fixtures")]
        ),
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
