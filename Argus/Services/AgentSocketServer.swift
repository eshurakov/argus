import Darwin
import Foundation

/// Version-one newline-delimited JSON Unix Domain Socket server.
///
/// The server owns only the path it successfully bound. Its actor isolation
/// serializes listener/client ownership; Workspace state is reached solely by
/// hopping through the injected MainActor delivery closure.
actor AgentSocketServer {
    static let protocolVersion = 1
    static let defaultMaximumFrameBytes = 64 * 1024

    private let path: String
    private let maximumFrameBytes: Int
    private let deliver: @MainActor @Sendable (TurnCompletionEvent) -> TurnCompletionDeliveryResult

    private var listener: Int32?
    private let clients = AgentSocketClientRegistry()
    private var ownsPath = false

    init(
        path: String,
        maximumFrameBytes: Int = AgentSocketServer.defaultMaximumFrameBytes,
        deliver: @escaping @MainActor @Sendable (TurnCompletionEvent) -> TurnCompletionDeliveryResult
    ) {
        self.path = path
        self.maximumFrameBytes = maximumFrameBytes
        self.deliver = deliver
    }

    deinit {
        if let listener {
            Darwin.close(listener)
        }
        clients.shutdownAll()
        if ownsPath {
            _ = unlink(path)
        }
    }

    func start() throws {
        guard listener == nil else { return }
        guard maximumFrameBytes > 0 else { throw AgentSocketServerError.invalidFrameLimit }
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw AgentSocketServerError.pathTooLong
        }
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try removeStaleSocketIfNeeded()

        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { throw AgentSocketServerError.systemCall("socket") }

        do {
            try bind(socket)
            ownsPath = true
            guard chmod(path, S_IRUSR | S_IWUSR) == 0 else {
                throw AgentSocketServerError.systemCall("chmod")
            }
            guard Darwin.listen(socket, SOMAXCONN) == 0 else {
                throw AgentSocketServerError.systemCall("listen")
            }
            listener = socket
            let clients = clients
            let maximumFrameBytes = maximumFrameBytes
            let deliver = deliver
            Task.detached {
                Self.acceptConnections(
                    on: socket,
                    clients: clients,
                    maximumFrameBytes: maximumFrameBytes,
                    deliver: deliver
                )
            }
        } catch {
            Darwin.close(socket)
            if ownsPath {
                _ = unlink(path)
                ownsPath = false
            }
            throw error
        }
    }

    private func bind(_ socket: Int32) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: pathBytes)
        }
        let addressLength = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socket, $0, addressLength)
            }
        }
        guard result == 0 else { throw AgentSocketServerError.systemCall("bind") }
    }

    private func removeStaleSocketIfNeeded() throws {
        var status = stat()
        guard lstat(path, &status) == 0 else {
            guard errno == ENOENT else { throw AgentSocketServerError.systemCall("lstat") }
            return
        }
        guard (status.st_mode & S_IFMT) == S_IFSOCK else {
            throw AgentSocketServerError.pathAlreadyExists
        }
        try ensureSocketIsStale()
        guard unlink(path) == 0 else { throw AgentSocketServerError.systemCall("unlink") }
    }

    private func ensureSocketIsStale() throws {
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { throw AgentSocketServerError.systemCall("socket") }
        defer { Darwin.close(socket) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: pathBytes)
        }
        let addressLength = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, addressLength)
            }
        }
        guard result != 0 else { throw AgentSocketServerError.liveListener }

        switch errno {
        case ECONNREFUSED, ENOENT:
            return
        default:
            throw AgentSocketServerError.systemCall("connect")
        }
    }

    func shutdown() {
        guard let listener else { return }
        self.listener = nil
        Darwin.shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
        clients.shutdownAll()
        if ownsPath {
            _ = unlink(path)
            ownsPath = false
        }
    }

    private nonisolated static func acceptConnections(
        on listener: Int32,
        clients: AgentSocketClientRegistry,
        maximumFrameBytes: Int,
        deliver: @escaping @MainActor @Sendable (TurnCompletionEvent) -> TurnCompletionDeliveryResult
    ) {
        while true {
            let client = Darwin.accept(listener, nil, nil)
            guard client >= 0 else { break }
            var noSigPipe: Int32 = 1
            let optionLength = socklen_t(MemoryLayout.size(ofValue: noSigPipe))
            guard setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, optionLength) == 0 else {
                Darwin.close(client)
                continue
            }
            clients.insert(client)
            Task.detached {
                await Self.serve(
                    client: client,
                    clients: clients,
                    maximumFrameBytes: maximumFrameBytes,
                    deliver: deliver
                )
            }
        }
    }

    private nonisolated static func serve(
        client: Int32,
        clients: AgentSocketClientRegistry,
        maximumFrameBytes: Int,
        deliver: @escaping @MainActor @Sendable (TurnCompletionEvent) -> TurnCompletionDeliveryResult
    ) async {
        defer {
            Darwin.close(client)
            clients.remove(client)
        }

        var buffered = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let received = Darwin.recv(client, &bytes, bytes.count, 0)
            guard received > 0 else { return }
            buffered.append(contentsOf: bytes.prefix(received))

            while let newline = buffered.firstIndex(of: 0x0A) {
                let frame = buffered.prefix(upTo: newline)
                buffered.removeSubrange(...newline)
                if frame.count > maximumFrameBytes {
                    writeResponse(
                        .failure(id: nil, code: .frameTooLarge, message: "Frame exceeds maximum size"), to: client)
                    return
                }
                let response = await handle(frame: Data(frame), deliver: deliver)
                writeResponse(response, to: client)
            }

            if buffered.count > maximumFrameBytes {
                writeResponse(
                    .failure(id: nil, code: .frameTooLarge, message: "Frame exceeds maximum size"), to: client)
                return
            }
        }
    }

    private nonisolated static func handle(
        frame: Data,
        deliver: @escaping @MainActor @Sendable (TurnCompletionEvent) -> TurnCompletionDeliveryResult
    ) async -> AgentSocketResponse {
        let request: AgentSocketRequest
        do {
            request = try JSONDecoder().decode(AgentSocketRequest.self, from: frame)
        } catch {
            return .failure(id: nil, code: .malformedRequest, message: "Malformed JSON request")
        }

        guard request.version == Self.protocolVersion else {
            return .failure(id: request.id, code: .unsupportedVersion, message: "Unsupported protocol version")
        }
        guard request.method == "agent.turnCompleted" else {
            return .failure(id: request.id, code: .unknownMethod, message: "Unknown method")
        }
        guard let params = request.params,
            Self.isBounded(params.agentKey, maximumLength: 128),
            Self.isBounded(params.eventId, maximumLength: 512),
            let workspaceId = UUID(uuidString: params.workspaceId),
            let surfaceId = UUID(uuidString: params.surfaceId)
        else {
            return .failure(id: request.id, code: .invalidParameters, message: "Invalid turn completion parameters")
        }

        let event = TurnCompletionEvent(
            agentKey: params.agentKey,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            eventId: params.eventId
        )
        let result = await deliver(event)
        switch result {
        case .accepted(let requiresAttention):
            return .success(id: request.id, requiresAttention: requiresAttention)
        case .rejected(let code, let message):
            return .failure(id: request.id, code: .unknownTerminalSurface, message: message + " (\(code.rawValue))")
        }
    }

    private nonisolated static func isBounded(_ value: String, maximumLength: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumLength
    }

    private nonisolated static func writeResponse(_ response: AgentSocketResponse, to socket: Int32) {
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var written = 0
            while written < data.count {
                let result = Darwin.send(socket, baseAddress.advanced(by: written), data.count - written, 0)
                guard result > 0 else { return }
                written += result
            }
        }
    }
}

private final class AgentSocketClientRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var sockets: Set<Int32> = []

    func insert(_ socket: Int32) {
        _ = lock.withLock { sockets.insert(socket) }
    }

    func remove(_ socket: Int32) {
        _ = lock.withLock { sockets.remove(socket) }
    }

    func shutdownAll() {
        let currentSockets = lock.withLock { Array(sockets) }
        for socket in currentSockets {
            Darwin.shutdown(socket, SHUT_RDWR)
        }
    }
}

enum AgentSocketServerError: Error, Equatable {
    case invalidFrameLimit
    case pathTooLong
    case pathAlreadyExists
    case liveListener
    case systemCall(String)
}

private struct AgentSocketRequest: Decodable {
    let version: Int
    let id: String?
    let method: String
    let params: AgentSocketTurnCompletedParameters?
}

private struct AgentSocketTurnCompletedParameters: Decodable {
    let agentKey: String
    let workspaceId: String
    let surfaceId: String
    let eventId: String
}

private struct AgentSocketResponse: Encodable {
    let id: String?
    let isSuccessful: Bool
    let result: Result?
    let error: Failure?

    struct Result: Encodable {
        let accepted: Bool
        let requiresAttention: Bool
    }

    struct Failure: Encodable {
        let code: AgentSocketErrorCode
        let message: String
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case isSuccessful = "ok"
        case result
        case error
    }

    static func success(id: String?, requiresAttention: Bool) -> Self {
        Self(
            id: id, isSuccessful: true, result: Result(accepted: true, requiresAttention: requiresAttention), error: nil
        )
    }

    static func failure(id: String?, code: AgentSocketErrorCode, message: String) -> Self {
        Self(id: id, isSuccessful: false, result: nil, error: Failure(code: code, message: message))
    }
}

private enum AgentSocketErrorCode: String, Encodable {
    case malformedRequest = "malformed_request"
    case unsupportedVersion = "unsupported_version"
    case unknownMethod = "unknown_method"
    case invalidParameters = "invalid_parameters"
    case unknownTerminalSurface = "unknown_terminal_surface"
    case frameTooLarge = "frame_too_large"
}
