// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OMEMO",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "OMEMO", targets: ["OMEMO"])
    ],
    dependencies: [
        .package(path: "../CurveMath"),
        .package(path: "../XMPPCore"),
    ],
    targets: [
        .target(
            name: "OMEMO",
            dependencies: [
                .product(name: "CurveMath", package: "CurveMath"),
                .product(name: "XMPPCore", package: "XMPPCore"),
            ]
        ),
        .testTarget(
            name: "OMEMOTests",
            dependencies: [
                "OMEMO",
                .product(name: "CurveMath", package: "CurveMath"),
                .product(name: "XMPPCore", package: "XMPPCore"),
            ],
            resources: [.process("Resources")]
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
