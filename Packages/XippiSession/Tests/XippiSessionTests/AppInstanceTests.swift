import Foundation
import Testing

@testable import XippiSession

/// R83: one Xippi per user. The copy launched first runs; any later one gives way, and of
/// two launched at once exactly one does. The instance lock holds against every other open of
/// its file.
@Suite struct AppInstanceTests {
    typealias Running = AppInstance.Running

    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aLaterLaunchGivesWayToTheRunningOne() {
        let running = Running(processID: 400, launched: Self.start)
        let second = Running(processID: 500, launched: Self.start.addingTimeInterval(60))
        #expect(AppInstance.predecessor(of: second, among: [running, second]) == running)
        #expect(AppInstance.predecessor(of: running, among: [running, second]) == nil)
        #expect(AppInstance.predecessor(of: running, among: []) == nil)
    }

    /// Launched at the same moment, or with no date known: the lower process id runs, so the
    /// two never both quit.
    @Test func ofTwoLaunchesAtOnceExactlyOneGivesWay() {
        for launched in [Self.start, nil] {
            let first = Running(processID: 400, launched: launched)
            let second = Running(processID: 500, launched: launched)
            #expect(AppInstance.predecessor(of: second, among: [first]) == first)
            #expect(AppInstance.predecessor(of: first, among: [second]) == nil)
        }
    }

    /// Several earlier ones (a build from Xcode beside the installed app): the first.
    @Test func theFirstLaunchedIsTheOneToHandOverTo() {
        let installed = Running(processID: 900, launched: Self.start)
        let debug = Running(processID: 300, launched: Self.start.addingTimeInterval(5))
        let me = Running(processID: 950, launched: Self.start.addingTimeInterval(10))
        #expect(AppInstance.predecessor(of: me, among: [debug, installed, me]) == installed)
    }

    /// The outcome of a lock, without the lock: holding none, it is let go at once.
    static func outcome(_ file: URL) -> String {
        switch AppInstance.lock(file) {
        case .held: "held"
        case .taken: "taken"
        case .unavailable: "unavailable"
        }
    }

    /// Every other open of the file, as another process's would be, finds the lock taken
    /// until the holder lets go.
    @Test func theLockIsHeldUntilItsHolderLetsGo() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "AppInstanceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "xippi.lock")
        var first: AppInstance.Lock?
        if case .held(let lock) = AppInstance.lock(file) { first = lock }
        #expect(first != nil)
        #expect(Self.outcome(file) == "taken")
        first = nil
        #expect(Self.outcome(file) == "held")
    }

    @Test func aLockFileThatCannotBeOpenedSaysNothing() {
        #expect(Self.outcome(URL(filePath: "/dev/null/xippi.lock")) == "unavailable")
    }
}
