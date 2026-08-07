import Darwin
import Foundation
import Testing

@testable import Argus

private final class AgentStatusDeliverySpy: @unchecked Sendable {
    private let lock = NSLock()
    private var deliveredEvents: [AgentStatusEvent] = []

    func deliver(_ event: AgentStatusEvent) -> AgentStatusDeliveryResult {
        lock.withLock { deliveredEvents.append(event) }
        return .accepted(applied: true)
    }

    var events: [AgentStatusEvent] {
        lock.withLock { deliveredEvents }
    }
}

private struct StatusRequest {
    let id: String
    let method: String
    let workspaceId: UUID
    let surfaceId: UUID
    let state: String?
    let sequence: UInt64
}

@Suite(.serialized)
struct AgentStatusSocketTests {
    @Test
    func invalidStatusRequestsAreRejectedBeforeDelivery() async throws {
        let path = temporarySocketPath()
        let spy = AgentStatusDeliverySpy()
        let server = AgentSocketServer(
            path: path,
            deliver: { _ in .accepted(requiresAttention: false) },
            deliverStatus: { event in spy.deliver(event) }
        )

        let workspaceId = UUID()
        let surfaceId = UUID()
        let responses = try await withStartedServer(server) {
            let invalidState = try await send(
                statusRequest(
                    StatusRequest(
                        id: "invalid-state",
                        method: "agent.statusChanged",
                        workspaceId: workspaceId,
                        surfaceId: surfaceId,
                        state: "waiting",
                        sequence: 1
                    )
                ),
                to: path
            )
            let invalidSequence = try await send(
                statusRequest(
                    StatusRequest(
                        id: "invalid-sequence",
                        method: "agent.statusCleared",
                        workspaceId: workspaceId,
                        surfaceId: surfaceId,
                        state: nil,
                        sequence: 0
                    )
                ),
                to: path
            )
            return (invalidState, invalidSequence)
        }

        let invalidStateResponse = try decodeResponse(responses.0)
        let invalidSequenceResponse = try decodeResponse(responses.1)
        #expect(invalidStateResponse.error?.code == .invalidParameters)
        #expect(invalidSequenceResponse.error?.code == .invalidParameters)
        #expect(spy.events.isEmpty)
    }

    @Test
    func liveStatusRequestsSetAndClearTheReportedEntry() async throws {
        let path = temporarySocketPath()
        let spy = AgentStatusDeliverySpy()
        let server = AgentSocketServer(
            path: path,
            deliver: { _ in .accepted(requiresAttention: false) },
            deliverStatus: { event in spy.deliver(event) }
        )

        let workspaceId = UUID()
        let surfaceId = UUID()
        let responses = try await sendStatusChangeAndClear(
            server: server,
            path: path,
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )

        let changeDecoded = try decodeResponse(responses.0)
        let clearDecoded = try decodeResponse(responses.1)
        #expect(changeDecoded.id == "status-1")
        #expect(changeDecoded.isSuccessful)
        #expect(changeDecoded.result?.accepted == true)
        #expect(changeDecoded.result?.applied == true)
        #expect(clearDecoded.id == "status-clear-1")
        #expect(clearDecoded.isSuccessful)
        #expect(clearDecoded.result?.accepted == true)
        #expect(clearDecoded.result?.applied == true)
        #expect(
            spy.events == [
                statusEvent(workspaceId: workspaceId, surfaceId: surfaceId, state: .running, sequence: 1),
                statusEvent(workspaceId: workspaceId, surfaceId: surfaceId, state: nil, sequence: 2)
            ])
    }

    private func decodeResponse(_ text: String) throws -> AgentSocketResponse {
        try JSONDecoder().decode(AgentSocketResponse.self, from: Data(text.utf8))
    }

    private func statusRequest(_ request: StatusRequest) -> String {
        let stateParameter = request.state.map { ",\"state\":\"\($0)\"" } ?? ""
        let parameters =
            "\"agentKey\":\"pi\","
            + "\"workspaceId\":\"\(request.workspaceId.uuidString)\","
            + "\"surfaceId\":\"\(request.surfaceId.uuidString)\""
            + stateParameter
            + ",\"sessionId\":\"session-1\",\"sequence\":\(request.sequence)"
        return [
            "{\"version\":1,\"id\":\"\(request.id)\",",
            "\"method\":\"\(request.method)\",",
            "\"params\":{\(parameters)}}"
        ].joined()
    }

    private func sendStatusChangeAndClear(
        server: AgentSocketServer,
        path: String,
        workspaceId: UUID,
        surfaceId: UUID
    ) async throws -> (String, String) {
        try await withStartedServer(server) {
            let changeResponse = try await send(
                statusRequest(
                    StatusRequest(
                        id: "status-1",
                        method: "agent.statusChanged",
                        workspaceId: workspaceId,
                        surfaceId: surfaceId,
                        state: "running",
                        sequence: 1
                    )
                ),
                to: path
            )
            let clearResponse = try await send(
                statusRequest(
                    StatusRequest(
                        id: "status-clear-1",
                        method: "agent.statusCleared",
                        workspaceId: workspaceId,
                        surfaceId: surfaceId,
                        state: nil,
                        sequence: 2
                    )
                ),
                to: path
            )
            return (changeResponse, clearResponse)
        }
    }

    private func statusEvent(
        workspaceId: UUID,
        surfaceId: UUID,
        state: AgentStatusState?,
        sequence: UInt64
    ) -> AgentStatusEvent {
        AgentStatusEvent(
            agentKey: "pi",
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            state: state,
            sessionId: "session-1",
            sequence: sequence
        )
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
            let data = Data((request + "\n").utf8)
            try data.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                let sent = Darwin.send(socket, baseAddress, data.count, 0)
                guard sent == data.count else { throw SocketClientError.sendFailed }
            }
            var buffer = [UInt8](repeating: 0, count: 1024)
            let received = Darwin.recv(socket, &buffer, buffer.count, 0)
            guard received > 0 else { throw SocketClientError.receiveFailed }
            return String(bytes: buffer.prefix(received), encoding: .utf8) ?? ""
        }.value
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
    case sendFailed
    case receiveFailed
}

private func connectSynchronously(to path: String) throws -> Int32 {
    let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard socket >= 0 else { throw SocketClientError.receiveFailed }

    var address = socketAddress(for: path)
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(socket, $0, socketAddressLength(for: path))
        }
    }
    guard connected == 0 else {
        Darwin.close(socket)
        throw SocketClientError.receiveFailed
    }
    return socket
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
