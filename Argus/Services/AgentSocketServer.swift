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
    private let deliverStatus: @MainActor @Sendable (AgentStatusEvent) -> AgentStatusDeliveryResult

    private var listener: Int32?
    private let clients = AgentSocketClientRegistry()
    private var ownsPath = false

    init(
        path: String,
        maximumFrameBytes: Int = AgentSocketServer.defaultMaximumFrameBytes,
        deliver: @escaping @MainActor @Sendable (TurnCompletionEvent) -> TurnCompletionDeliveryResult,
        deliverStatus: @escaping @MainActor @Sendable (AgentStatusEvent) -> AgentStatusDeliveryResult = { _ in
            .rejected(code: .unavailable, message: "Agent Status delivery is unavailable")
        }
    ) {
        self.path = path
        self.maximumFrameBytes = maximumFrameBytes
        self.deliver = deliver
        self.deliverStatus = deliverStatus
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
            let deliverStatus = deliverStatus
            Task.detached {
                Self.acceptConnections(
                    on: socket,
                    clients: clients,
                    maximumFrameBytes: maximumFrameBytes,
                    deliver: deliver,
                    deliverStatus: deliverStatus
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
        deliver: @escaping @MainActor @Sendable (TurnCompletionEvent) -> TurnCompletionDeliveryResult,
        deliverStatus: @escaping @MainActor @Sendable (AgentStatusEvent) -> AgentStatusDeliveryResult
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
                    deliver: deliver,
                    deliverStatus: deliverStatus
                )
            }
        }
    }

    private nonisolated static func serve(
        client: Int32,
        clients: AgentSocketClientRegistry,
        maximumFrameBytes: Int,
        deliver: @escaping @MainActor @Sendable (TurnCompletionEvent) -> TurnCompletionDeliveryResult,
        deliverStatus: @escaping @MainActor @Sendable (AgentStatusEvent) -> AgentStatusDeliveryResult
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
                let response = await handle(
                    frame: Data(frame),
                    deliver: deliver,
                    deliverStatus: deliverStatus
                )
                writeResponse(response, to: client)
            }

            if buffered.count > maximumFrameBytes {
                writeResponse(
                    .failure(id: nil, code: .frameTooLarge, message: "Frame exceeds maximum size"), to: client)
                return
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
