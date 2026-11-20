import Foundation
import Testing
import XMPPCore
import XMPPTestSupport

@Suite(.timeLimit(.minutes(1))) struct FakeTransportTests {
    @Test func incomingComesBackOneStringPerReceive() async throws {
        let transport = FakeTransport()
        transport.enqueueIncoming("<a/>")
        transport.enqueueIncoming("<b/>")
        try await transport.open()
        #expect(try await transport.receiveString() == "<a/>")
        #expect(try await transport.receiveString() == "<b/>")
    }

    @Test func receiveWaitsForIncoming() async throws {
        let transport = FakeTransport()
        try await transport.open()
        let received = Task { try await transport.receiveString() }
        await transport.waitUntilSuspended(1)
        transport.enqueueIncoming("<late/>")
        #expect(try await received.value == "<late/>")
    }

    @Test func pathEventsAreScriptedAndEndOnClose() async throws {
        let transport = FakeTransport()
        let collected = Task {
            var events: [TransportPathEvent] = []
            for await event in transport.pathEvents { events.append(event) }
            return events
        }
        transport.simulatePathEvent(.viabilityChanged(false))
        transport.simulatePathEvent(.betterPathAvailable)
        transport.close()
        #expect(await collected.value == [.viabilityChanged(false), .betterPathAvailable])
    }

    @Test func sentIsRecorded() async throws {
        let transport = FakeTransport()
        try await transport.open()
        try await transport.send(Data("<x/>".utf8))
        try await transport.send(Data("<y/>".utf8))
        #expect(transport.sent == ["<x/>", "<y/>"])
    }

    @Test func responderAnswersEachSend() async throws {
        let transport = FakeTransport()
        transport.setResponder { sent in sent == "<ping/>" ? ["<pong/>"] : [] }
        try await transport.open()
        try await transport.send(Data("<other/>".utf8))
        try await transport.send(Data("<ping/>".utf8))
        #expect(try await transport.receiveString() == "<pong/>")
    }

    @Test func failNextOpenFailsOnce() async throws {
        let transport = FakeTransport()
        transport.failNextOpen(.connectFailed("refused"))
        await #expect(throws: TransportError.connectFailed("refused")) {
            try await transport.open()
        }
        try await transport.open()
    }

    @Test func failNextStartTLSFails() async throws {
        let transport = FakeTransport()
        try await transport.open()
        transport.failNextStartTLS(.tls("handshake"))
        await #expect(throws: TransportError.tls("handshake")) {
            _ = try await transport.startTLS(serverName: "example.com")
        }
        // Like the real transport, TLS is started once per transport, failed or not.
        await #expect(throws: TransportError.invalidCall("TLS already started")) {
            _ = try await transport.startTLS(serverName: "example.com")
        }
    }

    @Test func startTLSWhileReceivingIsRefused() async throws {
        let transport = FakeTransport()
        try await transport.open()
        let received = Task { try await transport.receiveString() }
        await transport.waitUntilSuspended(1)
        await #expect(throws: TransportError.invalidCall("receive in progress")) {
            _ = try await transport.startTLS(serverName: "example.com")
        }
        transport.enqueueIncoming("<proceed/>")
        #expect(try await received.value == "<proceed/>")
        _ = try await transport.startTLS(serverName: "example.com")
    }

    @Test func secondConcurrentReceiveIsRefused() async throws {
        let transport = FakeTransport()
        try await transport.open()
        let first = Task { try await transport.receiveString() }
        await transport.waitUntilSuspended(1)
        await #expect(throws: TransportError.invalidCall("receive already in progress")) {
            _ = try await transport.receive()
        }
        transport.enqueueIncoming("<a/>")
        #expect(try await first.value == "<a/>")
    }

    @Test func callsBeforeOpenAreRefused() async throws {
        let transport = FakeTransport()
        await #expect(throws: TransportError.invalidCall("not open")) {
            try await transport.send(Data("<x/>".utf8))
        }
        await #expect(throws: TransportError.invalidCall("not open")) {
            _ = try await transport.receive()
        }
        await #expect(throws: TransportError.invalidCall("not open")) {
            _ = try await transport.startTLS(serverName: "example.com")
        }
        #expect(transport.sent.isEmpty)
    }

    @Test func openTwiceIsRefused() async throws {
        let transport = FakeTransport()
        try await transport.open()
        await #expect(throws: TransportError.invalidCall("already open")) {
            try await transport.open()
        }
    }

    @Test func failNextSendFailsOnce() async throws {
        let transport = FakeTransport()
        try await transport.open()
        transport.failNextSend(.closed)
        await #expect(throws: TransportError.closed) { try await transport.send(Data("<x/>".utf8)) }
        try await transport.send(Data("<y/>".utf8))
        #expect(transport.sent == ["<y/>"])
    }

    @Test func startTLSReturnsTheScriptedInfo() async throws {
        let info = TLSInfo(serverCertificateChain: [Data([1, 2, 3])])
        let transport = FakeTransport(tlsInfo: info)
        try await transport.open()
        #expect(try await transport.startTLS(serverName: "example.com") == info)
        #expect(transport.startTLSServerNames == ["example.com"])
    }

    @Test func eofComesAfterQueuedData() async throws {
        let transport = FakeTransport()
        transport.enqueueIncoming("<a/>")
        transport.simulateEOF()
        try await transport.open()
        #expect(try await transport.receiveString() == "<a/>")
        #expect(try await transport.receive().isEmpty)
        #expect(try await transport.receive().isEmpty)
    }

    @Test func eofWakesAWaitingReceive() async throws {
        let transport = FakeTransport()
        try await transport.open()
        let received = Task { try await transport.receive() }
        await transport.waitUntilSuspended(1)
        transport.simulateEOF()
        #expect(try await received.value.isEmpty)
    }

    @Test func hangingOpenReturnsOnlyAtClose() async throws {
        let transport = FakeTransport()
        transport.simulateHang()
        let opened = Task { try await transport.open() }
        await transport.waitUntilSuspended(1)
        transport.close()
        await #expect(throws: TransportError.closed) { try await opened.value }
    }

    @Test func hangingStartTLSReturnsOnlyAtClose() async throws {
        let transport = FakeTransport()
        transport.simulateHang([.startTLS])
        try await transport.open()
        let secured = Task { try await transport.startTLS(serverName: "example.com") }
        await transport.waitUntilSuspended(1)
        transport.close()
        await #expect(throws: TransportError.closed) { _ = try await secured.value }
    }

    @Test func hangingReceiveDeliversWhatWasQueuedThenWaitsForClose() async throws {
        let transport = FakeTransport()
        transport.enqueueIncoming("<before/>")
        transport.simulateHang([.receive])
        transport.enqueueIncoming("<after/>")
        transport.simulateEOF()
        try await transport.open()
        #expect(try await transport.receiveString() == "<before/>")
        let received = Task { try await transport.receive() }
        await transport.waitUntilSuspended(1)
        transport.close()
        await #expect(throws: TransportError.closed) { _ = try await received.value }
    }

    @Test func cancellingAWaitingReceiveCloses() async throws {
        let transport = FakeTransport()
        try await transport.open()
        let received = Task { try await transport.receive() }
        await transport.waitUntilSuspended(1)
        received.cancel()
        await #expect(throws: TransportError.closed) { _ = try await received.value }
        #expect(transport.isClosed)
    }

    @Test func cancellingAHangingOpenCloses() async throws {
        let transport = FakeTransport()
        transport.simulateHang([.open])
        let opened = Task { try await transport.open() }
        await transport.waitUntilSuspended(1)
        opened.cancel()
        await #expect(throws: TransportError.closed) { try await opened.value }
        #expect(transport.isClosed)
    }

    @Test func closedTransportRefusesEverything() async throws {
        let transport = FakeTransport()
        transport.enqueueIncoming("<a/>")
        transport.close()
        transport.close()
        #expect(transport.isClosed)
        await #expect(throws: TransportError.closed) { try await transport.open() }
        await #expect(throws: TransportError.closed) { try await transport.send(Data("<x/>".utf8)) }
        await #expect(throws: TransportError.closed) { _ = try await transport.receive() }
        await #expect(throws: TransportError.closed) {
            _ = try await transport.startTLS(serverName: "x")
        }
    }
}

extension FakeTransport {
    fileprivate func receiveString() async throws -> String {
        String(decoding: try await receive(), as: UTF8.self)
    }

    /// Waits until `count` calls are suspended inside the transport.
    fileprivate func waitUntilSuspended(_ count: Int) async {
        while suspendedCalls < count {
            await Task.yield()
        }
    }
}
