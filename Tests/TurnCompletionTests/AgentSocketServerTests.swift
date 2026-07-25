import Darwin
import Foundation
import Testing

@testable import Argus

private final class TurnCompletionDeliverySpy: @unchecked Sendable {
    private let lock = NSLock()
    private var deliveredEvents: [TurnCompletionEvent] = []

    func deliver(_ event: TurnCompletionEvent) -> TurnCompletionDeliveryResult {
        lock.withLock { deliveredEvents.append(event) }
        return .accepted(requiresAttention: true)
    }

    var count: Int {
        lock.withLock { deliveredEvents.count }
    }
}

@Suite
struct AgentSocketServerTests {
    @Test
    func validRequestIsDeliveredAndReceivesCorrelatedSuccess() async throws {
        let path = temporarySocketPath()
        let spy = TurnCompletionDeliverySpy()
        let server = AgentSocketServer(path: path) { event in
            spy.deliver(event)
        }
        try await server.start()
        defer { Task { await server.shutdown() } }

        let workspaceId = UUID()
        let surfaceId = UUID()
        let parameters =
            "\"agentKey\":\"kilo\",\"workspaceId\":\"\(workspaceId.uuidString)\","
            + "\"surfaceId\":\"\(surfaceId.uuidString)\",\"eventId\":\"event-1\""
        let request =
            "{\"version\":1,\"id\":\"request-1\",\"method\":\"agent.turnCompleted\",\"params\":{\(parameters)}}"
        let response = try await send(request, to: path)

        #expect(response.contains("\"id\":\"request-1\""))
        #expect(response.contains("\"ok\":true"))
        #expect(response.contains("\"requiresAttention\":true"))
        #expect(spy.count == 1)
    }

    @Test
    func malformedAndOversizedFramesDoNotReachDelivery() async throws {
        let path = temporarySocketPath()
        let spy = TurnCompletionDeliverySpy()
        let server = AgentSocketServer(path: path, maximumFrameBytes: 32) { event in
            spy.deliver(event)
        }
        try await server.start()
        defer { Task { await server.shutdown() } }

        let malformed = try await send("not json", to: path)
        let oversized = try await send(String(repeating: "x", count: 33), to: path)

        #expect(malformed.contains("malformed_request"))
        #expect(oversized.contains("frame_too_large"))
        #expect(spy.count == 0)
    }

    @Test
    func fragmentedFrameIsDeliveredAndReceivesCorrelatedSuccess() async throws {
        let path = temporarySocketPath()
        let spy = TurnCompletionDeliverySpy()
        let server = AgentSocketServer(path: path) { event in
            spy.deliver(event)
        }
        try await server.start()
        defer { Task { await server.shutdown() } }

        let request = validRequest(id: "fragmented")
        let socket = try await connect(to: path)
        defer { Darwin.close(socket) }
        let midpoint = request.utf8.count / 2
        try send(String(request.prefix(midpoint)), on: socket, terminatesFrame: false)
        try send(String(request.dropFirst(midpoint)), on: socket)

        let responses = try await receiveResponses(on: socket, count: 1)
        let response = try #require(responses.first)
        #expect(response.contains("\"id\":\"fragmented\""))
        #expect(response.contains("\"ok\":true"))
        #expect(spy.count == 1)
    }

    @Test
    func persistentConnectionDeliversEachNewlineDelimitedFrame() async throws {
        let path = temporarySocketPath()
        let spy = TurnCompletionDeliverySpy()
        let server = AgentSocketServer(path: path) { event in
            spy.deliver(event)
        }
        try await server.start()
        defer { Task { await server.shutdown() } }

        let socket = try await connect(to: path)
        defer { Darwin.close(socket) }
        try send(validRequest(id: "first") + "\n" + validRequest(id: "second"), on: socket)

        let responses = try await receiveResponses(on: socket, count: 2)
        #expect(responses.count == 2)
        #expect(responses[0].contains("\"id\":\"first\""))
        #expect(responses[0].contains("\"ok\":true"))
        #expect(responses[1].contains("\"id\":\"second\""))
        #expect(responses[1].contains("\"ok\":true"))
        #expect(spy.count == 2)
    }

    @Test
    func disconnectedClientDoesNotStopServer() async throws {
        let path = temporarySocketPath()
        let spy = TurnCompletionDeliverySpy()
        let server = AgentSocketServer(path: path) { event in
            spy.deliver(event)
            Thread.sleep(forTimeInterval: 0.1)
            return .accepted(requiresAttention: true)
        }
        try await server.start()
        defer { Task { await server.shutdown() } }

        let request = validRequest(id: "disconnected-client")
        let socket = try await connect(to: path)
        try send(request, on: socket)
        try await waitUntil { spy.count == 1 }
        disconnectWithReset(socket)

        let response = try await send(validRequest(id: "subsequent-client"), to: path)
        #expect(response.contains("\"id\":\"subsequent-client\""))
        #expect(response.contains("\"ok\":true"))
        try await waitUntil { spy.count == 2 }
        #expect(spy.count == 2)
    }

    @Test
    func liveListenerIsPreserved() async throws {
        let path = temporarySocketPath()
        let firstServer = AgentSocketServer(path: path) { _ in
            .accepted(requiresAttention: false)
        }
        try await firstServer.start()
        defer { Task { await firstServer.shutdown() } }

        let secondServer = AgentSocketServer(path: path) { _ in
            .accepted(requiresAttention: false)
        }
        await #expect(throws: AgentSocketServerError.liveListener) {
            try await secondServer.start()
        }

        let response = try await send(validRequest(id: "first-server"), to: path)
        #expect(response.contains("\"id\":\"first-server\""))
        #expect(response.contains("\"ok\":true"))
    }

    @Test
    func staleSocketIsRemovedBeforeStarting() async throws {
        let path = temporarySocketPath()
        let staleSocket = try await bindSocket(at: path)
        Darwin.close(staleSocket)

        let server = AgentSocketServer(path: path) { _ in
            .accepted(requiresAttention: false)
        }
        try await server.start()
        defer { Task { await server.shutdown() } }

        let response = try await send(validRequest(id: "after-cleanup"), to: path)
        #expect(response.contains("\"id\":\"after-cleanup\""))
        #expect(response.contains("\"ok\":true"))
    }

    private func temporarySocketPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("argus-\(UUID().uuidString).sock")
            .path
    }

    private func send(_ request: String, to path: String) async throws -> String {
        try await Task.detached {
            let socket = try connectSynchronously(to: path)
            defer { Darwin.close(socket) }
            try sendSynchronously(request, on: socket)
            var buffer = [UInt8](repeating: 0, count: 1024)
            let received = Darwin.recv(socket, &buffer, buffer.count, 0)
            guard received > 0 else { throw SocketClientError.systemCall("recv") }
            return String(bytes: buffer.prefix(received), encoding: .utf8) ?? ""
        }.value
    }

    private func validRequest(id: String) -> String {
        let parameters =
            "\"agentKey\":\"kilo\",\"workspaceId\":\"\(UUID().uuidString)\","
            + "\"surfaceId\":\"\(UUID().uuidString)\",\"eventId\":\"event-\(id)\""
        return "{\"version\":1,\"id\":\"\(id)\",\"method\":\"agent.turnCompleted\",\"params\":{\(parameters)}}"
    }

    private func connect(to path: String) async throws -> Int32 {
        try await Task.detached { try connectSynchronously(to: path) }.value
    }

    private func send(_ request: String, on socket: Int32) throws {
        try sendSynchronously(request, on: socket)
    }

    private func send(_ request: String, on socket: Int32, terminatesFrame: Bool) throws {
        try sendSynchronously(request, on: socket, terminatesFrame: terminatesFrame)
    }

    private func receiveResponses(on socket: Int32, count: Int) async throws -> [String] {
        try await Task.detached { try receiveResponsesSynchronously(on: socket, count: count) }.value
    }

    private func disconnectWithReset(_ socket: Int32) {
        var linger = linger(l_onoff: 1, l_linger: 0)
        _ = setsockopt(socket, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout.size(ofValue: linger)))
        Darwin.close(socket)
    }

    private func waitUntil(_ condition: @escaping @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw SocketClientError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private enum SocketClientError: Error {
    case systemCall(String)
    case timedOut
}

private func connectSynchronously(to path: String) throws -> Int32 {
    let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard socket >= 0 else { throw SocketClientError.systemCall("socket") }

    var address = socketAddress(for: path)
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(socket, $0, socketAddressLength(for: path))
        }
    }
    guard connected == 0 else {
        Darwin.close(socket)
        throw SocketClientError.systemCall("connect")
    }
    return socket
}

private func bindSocket(at path: String) async throws -> Int32 {
    try await Task.detached {
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { throw SocketClientError.systemCall("socket") }

        var address = socketAddress(for: path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socket, $0, socketAddressLength(for: path))
            }
        }
        guard bound == 0 else {
            Darwin.close(socket)
            throw SocketClientError.systemCall("bind")
        }
        return socket
    }.value
}

private func sendSynchronously(_ request: String, on socket: Int32, terminatesFrame: Bool = true) throws {
    let data = Data((request + (terminatesFrame ? "\n" : "")).utf8)
    try data.withUnsafeBytes { bytes in
        guard let baseAddress = bytes.baseAddress,
            data.count > 0
        else { return }
        var written = 0
        while written < data.count {
            let result = Darwin.send(socket, baseAddress.advanced(by: written), data.count - written, 0)
            guard result > 0 else { throw SocketClientError.systemCall("send") }
            written += result
        }
    }
}

private func receiveResponsesSynchronously(on socket: Int32, count: Int) throws -> [String] {
    var buffered = Data()
    var responses: [String] = []
    var bytes = [UInt8](repeating: 0, count: 1024)

    while responses.count < count {
        let received = Darwin.recv(socket, &bytes, bytes.count, 0)
        guard received > 0 else { throw SocketClientError.systemCall("recv") }
        buffered.append(contentsOf: bytes.prefix(received))
        while let newline = buffered.firstIndex(of: 0x0A), responses.count < count {
            let response = buffered.prefix(upTo: newline)
            buffered.removeSubrange(...newline)
            guard let text = String(data: response, encoding: .utf8) else {
                throw SocketClientError.systemCall("invalid response")
            }
            responses.append(text)
        }
    }
    return responses
}

private func socketAddress(for path: String) -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8) + [0]
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        destination.copyBytes(from: pathBytes)
    }
    return address
}

private func socketAddressLength(for path: String) -> socklen_t {
    socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
}
