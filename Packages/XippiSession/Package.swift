// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "XippiSession",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "XippiSession", targets: ["XippiSession"])
    ],
    dependencies: [
        .package(path: "../XMPPCore"),
        .package(path: "../XippiStore"),
        .package(path: "../CurveMath"),
        .package(path: "../OMEMO"),
        .package(path: "../XippiCalls"),
    ],
    targets: [
        .target(
            name: "XippiSession",
            dependencies: [
                .product(name: "XMPPCore", package: "XMPPCore"),
                .product(name: "XippiStore", package: "XippiStore"),
                .product(name: "CurveMath", package: "CurveMath"),
                .product(name: "OMEMO", package: "OMEMO"),
                .product(name: "XippiCalls", package: "XippiCalls"),
            ]
        ),
        .testTarget(
            name: "XippiSessionTests",
            dependencies: [
                "XippiSession",
                .product(name: "XMPPTestSupport", package: "XMPPCore"),
            ]
        ),
        // Against the test servers (`make up`), only with XIPPI_INTEGRATION=1;
        // `make test-integration-disruptive` adds the tests that restart a server.
        .testTarget(
            name: "XMPPIntegrationTests",
            dependencies: [
                "XippiSession",
                .product(name: "XMPPCore", package: "XMPPCore"),
                .product(name: "XippiStore", package: "XippiStore"),
                .product(name: "OMEMO", package: "OMEMO"),
                .product(name: "XMPPTestSupport", package: "XMPPCore"),
            ]
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
