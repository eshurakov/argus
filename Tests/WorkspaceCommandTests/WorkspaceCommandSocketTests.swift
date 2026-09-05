import Darwin
import Foundation
import Testing

@testable import Argus

private final class WorkspaceCommandSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [WorkspaceCommandRequest] = []
    private let outcome: WorkspaceCommandOutcome

    init(outcome: WorkspaceCommandOutcome) {
        self.outcome = outcome
    }

    func deliver(_ request: WorkspaceCommandRequest) -> WorkspaceCommandOutcome {
        lock.withLock { received.append(request) }
        return outcome
    }

    var requests: [WorkspaceCommandRequest] {
        lock.withLock { received }
    }
}

@Suite(.serialized)
struct WorkspaceCommandSocketTests {
    @Test
    func listRequestsNeedNoParametersAndReturnTheProjection() async throws {
        let spy = WorkspaceCommandSpy(outcome: .list(Self.listResult))
        let response = await AgentSocketServer.handle(
            frame: Data(#"{"version":1,"id":"list-1","method":"workspace.list"}"#.utf8),
            handlers: Self.handlers(spy)
        )

        let decoded = try Self.decode(response, as: WorkspaceListResult.self)
        #expect(decoded.id == "list-1")
        #expect(decoded.isSuccessful)
        #expect(decoded.result?.projects.first?.name == "argus")
        #expect(spy.requests.count == 1)
        guard case .list = try #require(spy.requests.first) else {
            Issue.record("workspace.list did not deliver a list request")
            return
        }
    }

    @Test
    func createRequestsDeliverTheirParametersVerbatim() async throws {
        let spy = WorkspaceCommandSpy(outcome: .created(Self.createResult))
        let parameters =
            #"{"project":"argus","base":".","branch":"feature/child","name":"Child","#
            + #""contextWorkspaceId":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","contextDirectory":"/tmp"}"#
        let response = await AgentSocketServer.handle(
            frame: Data(
                #"{"version":1,"id":"create-1","method":"workspace.create","params":\#(parameters)}"#.utf8),
            handlers: Self.handlers(spy)
        )

        let decoded = try Self.decode(response, as: WorkspaceCreateResult.self)
        #expect(decoded.id == "create-1")
        #expect(decoded.result?.branch == "feature/child")
        #expect(decoded.result?.recordedBaseBranch == true)
        guard case .create(let delivered) = try #require(spy.requests.first) else {
            Issue.record("workspace.create did not deliver a create request")
            return
        }
        #expect(delivered.project == "argus")
        #expect(delivered.base == ".")
        #expect(delivered.branch == "feature/child")
        #expect(delivered.name == "Child")
        #expect(delivered.contextWorkspaceId == "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")
        #expect(delivered.contextDirectory == "/tmp")
    }

    @Test
    func rejectionsAndUnknownMethodsBecomeStructuredFailures() async throws {
        let spy = WorkspaceCommandSpy(
            outcome: .rejected(code: .unknownProject, message: "No Project named 'nope'"))
        let rejected = await AgentSocketServer.handle(
            frame: Data(#"{"version":1,"id":"create-2","method":"workspace.create","params":{}}"#.utf8),
            handlers: Self.handlers(spy)
        )
        let unknown = await AgentSocketServer.handle(
            frame: Data(#"{"version":1,"id":"other","method":"workspace.destroy"}"#.utf8),
            handlers: Self.handlers(spy)
        )

        let rejectedResponse = try Self.decode(rejected, as: WorkspaceCreateResult.self)
        #expect(!rejectedResponse.isSuccessful)
        #expect(rejectedResponse.errorCode == .unknownProject)
        #expect(rejectedResponse.error?.message == "No Project named 'nope'")
        let unknownResponse = try Self.decode(unknown, as: WorkspaceCreateResult.self)
        #expect(unknownResponse.errorCode == .unknownMethod)
        #expect(spy.requests.count == 1)
    }

    @Test
    func aListRequestCompletesOverTheSocket() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("argus-\(UUID().uuidString).sock").path
        let spy = WorkspaceCommandSpy(outcome: .list(Self.listResult))
        let server = AgentSocketServer(
            path: path,
            deliver: { _ in .accepted(requiresAttention: false) },
            deliverCommand: { request in spy.deliver(request) }
        )
        try await server.start()
        defer { Task { await server.shutdown() } }

        let line = try await Task.detached {
            try sendLine(#"{"version":1,"id":"socket-1","method":"workspace.list"}"#, to: path)
        }.value
        await server.shutdown()

        let decoded = try JSONDecoder().decode(
            ArgusSocketResponse<WorkspaceListResult>.self, from: Data(line.utf8))
        #expect(decoded.id == "socket-1")
        #expect(decoded.isSuccessful)
        #expect(decoded.result?.selectedWorkspaceId == Self.listResult.selectedWorkspaceId)
        #expect(spy.requests.count == 1)
    }

    // MARK: - Helpers

    private static func handlers(_ spy: WorkspaceCommandSpy) -> AgentSocketHandlers {
        AgentSocketHandlers(
            deliver: { _ in .accepted(requiresAttention: false) },
            deliverStatus: { _ in .accepted(applied: false) },
            deliverCommand: { request in spy.deliver(request) }
        )
    }

    private static func decode<Payload: Codable & Sendable>(
        _ response: AgentSocketEncodedResponse,
        as payload: Payload.Type
    ) throws -> ArgusSocketResponse<Payload> {
        try JSONDecoder().decode(ArgusSocketResponse<Payload>.self, from: response.data)
    }

    private static let entry = WorkspaceListEntry(
        id: "6E9AB0B1-8F1B-4C24-9D1E-5B5A0C2C8B44",
        number: 1,
        title: "feature/child",
        kind: .worktree,
        branch: "feature/child",
        root: "/tmp/child",
        worktreePath: "/tmp/child",
        isSelected: false,
        tabCount: 1
    )

    private static let listResult = WorkspaceListResult(
        selectedWorkspaceId: "1D1F1B6C-4B0E-4C64-9E8A-6C0A5D6A7B21",
        projects: [
            ProjectListEntry(
                id: "9F1E2D3C-4B5A-4697-8899-AABBCCDDEEFF",
                name: "argus",
                isCatchAll: false,
                repositoryPath: "/tmp/argus",
                mainBranch: "main",
                stackDiagnostic: nil,
                items: [.workspace(entry)]
            )
        ]
    )

    private static let createResult = WorkspaceCreateResult(
        workspace: entry,
        projectId: "9F1E2D3C-4B5A-4697-8899-AABBCCDDEEFF",
        projectName: "argus",
        branch: "feature/child",
        baseBranch: "feature/parent",
        recordedBaseBranch: true
    )
}

private enum SocketTestError: Error {
    case systemCall(String)
}

/// Minimal one-frame client: the transport itself is covered by the agent
/// socket tests, so this only proves a Workspace Command completes end to end.
private func sendLine(_ request: String, to path: String) throws -> String {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8) + [0]
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
    let length = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)

    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw SocketTestError.systemCall("socket") }
    defer { Darwin.close(descriptor) }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(descriptor, $0, length)
        }
    }
    guard connected == 0 else { throw SocketTestError.systemCall("connect") }

    let frame = Data((request + "\n").utf8)
    try frame.withUnsafeBytes { bytes in
        guard let base = bytes.baseAddress else { throw SocketTestError.systemCall("send") }
        var written = 0
        while written < frame.count {
            let sent = Darwin.send(descriptor, base.advanced(by: written), frame.count - written, 0)
            guard sent > 0 else { throw SocketTestError.systemCall("send") }
            written += sent
        }
    }

    var buffered = Data()
    var bytes = [UInt8](repeating: 0, count: 4096)
    while !buffered.contains(0x0A) {
        let received = Darwin.recv(descriptor, &bytes, bytes.count, 0)
        guard received > 0 else { throw SocketTestError.systemCall("recv") }
        buffered.append(contentsOf: bytes.prefix(received))
    }
    guard let newline = buffered.firstIndex(of: 0x0A),
        let line = String(data: buffered.prefix(upTo: newline), encoding: .utf8)
    else { throw SocketTestError.systemCall("decode") }
    return line
}
