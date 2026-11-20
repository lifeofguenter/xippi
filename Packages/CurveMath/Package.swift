// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CurveMath",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CurveMath", targets: ["CurveMath"])
    ],
    targets: [
        .target(name: "CurveMath"),
        .testTarget(
            name: "CurveMathTests",
            dependencies: ["CurveMath"],
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
