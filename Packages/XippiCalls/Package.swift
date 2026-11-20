// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "XippiCalls",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "XippiCalls", targets: ["XippiCalls"])
    ],
    dependencies: [
        .package(path: "../XMPPCore"),
        .package(url: "https://github.com/stasel/WebRTC", exact: "158.0.0"),
    ],
    targets: [
        .target(
            name: "XippiCalls",
            dependencies: [
                .product(name: "XMPPCore", package: "XMPPCore"),
                .product(name: "WebRTC", package: "WebRTC"),
            ]
        ),
        .testTarget(
            name: "XippiCallsTests",
            dependencies: [
                "XippiCalls",
                .product(name: "XMPPCore", package: "XMPPCore"),
                .product(name: "XMPPTestSupport", package: "XMPPCore"),
                .product(name: "WebRTC", package: "WebRTC"),
            ],
            resources: [.process("Fixtures")]
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
