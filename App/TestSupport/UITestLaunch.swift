#if DEBUG || UITEST_HOOKS
    import Foundation
    import Security
    import os

    /// Whether the UI tests launched the app, with `-UITestSeed <count>`,
    /// `-UITestDatabase memory` or `-UITestDatabaseFile <name>`, or it hosts the unit tests. Only then does it use a test
    /// database (in memory, or a file in its container) and show the test probes. With any of
    /// them, `-UITestCA <path>` trusts the test servers' CA (PEM or DER) beside the system's
    /// roots, and `-UITestServer <host>` is where new accounts connect (`TestServer`). Such a
    /// launch is not held to one instance (`SingleInstance`) unless
    /// `-UITestSingleInstance YES` asks for it. Built only into Debug and the Performance
    /// configuration (the `UITEST_HOOKS` condition), never into Release, and read only from the
    /// process's own arguments: no defaults domain can switch it on.
    enum UITestLaunch {
        private static let arguments = ProcessInfo.processInfo.arguments

        /// The value after `-<name>` in the launch arguments.
        static func value(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: "-\(name)"), index + 1 < arguments.count
            else { return nil }
            return arguments[index + 1]
        }

        static let isActive =
            value("UITestSeed") != nil || value("UITestDatabase") == "memory"
            || value("UITestDatabaseFile") != nil || hostsUnitTests

        /// The app is the host of the unit tests (`XippiTests`): it starts as for the UI tests,
        /// on an empty database in memory, so the tests never open the user's store or connect
        /// an account. Read from the environment the test runner sets for its host.
        static let hostsUnitTests =
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil

        /// `-UITestDatabaseFile <name>`: an on-disk database of that name in the container's
        /// temporary folder, kept between launches (the launch measurement). Only the file name
        /// counts.
        static var databaseFile: URL? {
            guard let name = value("UITestDatabaseFile") else { return nil }
            let file = (name as NSString).lastPathComponent
            guard !file.isEmpty, file != ".", file != ".." else { return nil }
            return FileManager.default.temporaryDirectory
                .appending(path: "UITestDatabases", directoryHint: .isDirectory)
                .appending(path: file, directoryHint: .notDirectory)
        }

        /// `-UITestChats <n>`: how many chats to seed (40 without it).
        static var chatCount: Int {
            value("UITestChats").flatMap(Int.init).map { min(max($0, 1), 500) } ?? 40
        }

        /// `-UITestSeed store`: the App Store screenshots' chats (`StoreSample`).
        static var seedsStore: Bool { value("UITestSeed") == "store" }

        /// The number of messages to seed into the big chat, when seeding.
        static var seedCount: Int? {
            value("UITestSeed").map { max(Int($0) ?? 0, 0) }
        }

        /// The certificate named by `-UITestCA`: a file (PEM or DER) the sandbox lets the app
        /// read, such as one in its container, or the certificate itself, PEM or base64 DER,
        /// since the sandbox keeps the app out of the repository. None without the argument.
        static var extraAnchors: [SecCertificate] {
            guard let value = value("UITestCA") else { return [] }
            let data = FileManager.default.contents(atPath: value) ?? Data(value.utf8)
            let der = pemBody(data) ?? Data(base64Encoded: data) ?? data
            guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
                appLog.error("Test CA not read")
                return []
            }
            return [certificate]
        }

        /// The DER inside a PEM file's first certificate block.
        private static func pemBody(_ data: Data) -> Data? {
            guard let text = String(data: data, encoding: .utf8),
                let start = text.range(of: "-----BEGIN CERTIFICATE-----"),
                let end = text.range(
                    of: "-----END CERTIFICATE-----", range: start.upperBound..<text.endIndex)
            else { return nil }
            let body = text[start.upperBound..<end.lowerBound].filter { !$0.isWhitespace }
            return Data(base64Encoded: String(body))
        }
    }
#endif
