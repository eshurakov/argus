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

@Suite(.serialized)
struct AgentSocketServerTests {
    @Test
    func validRequestIsDeliveredAndReceivesCorrelatedSuccess() async throws {
        let path = temporarySocketPath()
        let spy = TurnCompletionDeliverySpy()
        let server = AgentSocketServer(path: path) { event in
            spy.deliver(event)
        }
        let workspaceId = UUID()
        let surfaceId = UUID()
        let parameters =
            "\"agentKey\":\"kilo\",\"workspaceId\":\"\(workspaceId.uuidString)\","
            + "\"surfaceId\":\"\(surfaceId.uuidString)\",\"eventId\":\"event-1\""
        let request =
            "{\"version\":1,\"id\":\"request-1\",\"method\":\"agent.turnCompleted\",\"params\":{\(parameters)}}"
        let response = try await withStartedServer(server) {
            try await send(request, to: path)
        }

        let decoded = try decodeResponse(response)
        #expect(decoded.id == "request-1")
        #expect(decoded.isSuccessful)
        #expect(decoded.result?.accepted == true)
        #expect(decoded.result?.requiresAttention == true)
        #expect(spy.count == 1)
    }

    @Test
    func malformedAndOversizedFramesDoNotReachDelivery() async throws {
        let path = temporarySocketPath()
        let spy = TurnCompletionDeliverySpy()
        let server = AgentSocketServer(path: path, maximumFrameBytes: 32) { event in
            spy.deliver(event)
        }
        let responses = try await withStartedServer(server) {
            let malformed = try await send("not json", to: path)
            let oversized = try await send(String(repeating: "x", count: 33), to: path)
            return (malformed, oversized)
        }
        let malformed = responses.0
        let oversized = responses.1

        let malformedResponse = try decodeResponse(malformed)
        let oversizedResponse = try decodeResponse(oversized)
        #expect(malformedResponse.error?.code == .malformedRequest)
        #expect(oversizedResponse.error?.code == .frameTooLarge)
        #expect(spy.count == 0)
    }

    @Test
    func fragmentedFrameIsDeliveredAndReceivesCorrelatedSuccess() async throws {
        let path = temporarySocketPath()
        let spy = TurnCompletionDeliverySpy()
        let server = AgentSocketServer(path: path) { event in
            spy.deliver(event)
        }
        let responses = try await withStartedServer(server) {
            let request = validRequest(id: "fragmented")
            let socket = try await connect(to: path)
            defer { Darwin.close(socket) }
            let midpoint = request.utf8.count / 2
            try send(String(request.prefix(midpoint)), on: socket, terminatesFrame: false)
            try send(String(request.dropFirst(midpoint)), on: socket)
            return try await receiveResponses(on: socket, count: 1)
        }
        let response = try #require(responses.first)
        let decoded = try decodeResponse(response)
        #expect(decoded.id == "fragmented")
        #expect(decoded.isSuccessful)
        #expect(decoded.result?.accepted == true)
        #expect(spy.count == 1)
    }

    @Test
    func persistentConnectionDeliversEachNewlineDelimitedFrame() async throws {
        let path = temporarySocketPath()
        let spy = TurnCompletionDeliverySpy()
        let server = AgentSocketServer(path: path) { event in
            spy.deliver(event)
        }
        let responses = try await withStartedServer(server) {
            let socket = try await connect(to: path)
            defer { Darwin.close(socket) }
            try send(validRequest(id: "first") + "\n" + validRequest(id: "second"), on: socket)
            return try await receiveResponses(on: socket, count: 2)
        }
        let decoded = try responses.map(decodeResponse)
        #expect(decoded.count == 2)
        #expect(decoded[0].id == "first")
        #expect(decoded[0].isSuccessful)
        #expect(decoded[0].result?.accepted == true)
        #expect(decoded[1].id == "second")
        #expect(decoded[1].isSuccessful)
        #expect(decoded[1].result?.accepted == true)
        #expect(spy.count == 2)
    }

    @Test
    func closedClientDoesNotStopServer() async throws {
        let path = temporarySocketPath()
        let spy = TurnCompletionDeliverySpy()
        let server = AgentSocketServer(path: path) { event in
            _ = spy.deliver(event)
            return .accepted(requiresAttention: true)
        }
        let responses = try await withStartedServer(server) {
            let first = try await send(validRequest(id: "closed-client"), to: path)
            let second = try await send(validRequest(id: "subsequent-client"), to: path)
            return (first, second)
        }
        let firstDecoded = try decodeResponse(responses.0)
        let secondDecoded = try decodeResponse(responses.1)
        #expect(firstDecoded.id == "closed-client")
        #expect(firstDecoded.isSuccessful)
        #expect(secondDecoded.id == "subsequent-client")
        #expect(secondDecoded.isSuccessful)
        #expect(spy.count == 2)
    }

    @Test
    func liveListenerIsPreserved() async throws {
        let path = temporarySocketPath()
        let firstServer = AgentSocketServer(path: path) { _ in
            .accepted(requiresAttention: false)
        }
        let response = try await withStartedServer(firstServer) {
            let secondServer = AgentSocketServer(path: path) { _ in
                .accepted(requiresAttention: false)
            }
            await #expect(throws: AgentSocketServerError.liveListener) {
                try await secondServer.start()
            }
            return try await send(validRequest(id: "first-server"), to: path)
        }
        let decoded = try decodeResponse(response)
        #expect(decoded.id == "first-server")
        #expect(decoded.isSuccessful)
        #expect(decoded.result?.accepted == true)
    }

    @Test
    func staleSocketIsRemovedBeforeStarting() async throws {
        let path = temporarySocketPath()
        let staleSocket = try await bindSocket(at: path)
        Darwin.close(staleSocket)

        let server = AgentSocketServer(path: path) { _ in
            .accepted(requiresAttention: false)
        }
        let response = try await withStartedServer(server) {
            try await send(validRequest(id: "after-cleanup"), to: path)
        }
        let decoded = try decodeResponse(response)
        #expect(decoded.id == "after-cleanup")
        #expect(decoded.isSuccessful)
        #expect(decoded.result?.accepted == true)
    }

    private func decodeResponse(_ text: String) throws -> AgentSocketResponse {
        try JSONDecoder().decode(AgentSocketResponse.self, from: Data(text.utf8))
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

}

private func withStartedServer<Value>(
    _ server: AgentSocketServer,
    operation: () async throws -> Value
) async throws -> Value {
    try await server.start()
    do {
        let value = try await operation()
        await server.shutdown()
        return value
    } catch {
        await server.shutdown()
        throw error
    }
}

private enum SocketClientError: Error {
    case systemCall(String)
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
