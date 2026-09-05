import ArgusIPC
import Darwin
import Foundation

/// Newline-delimited JSON client for the app-owned Unix Domain Socket.
///
/// This is the whole of the Companion CLI's knowledge about Argus: it encodes
/// one request, reads one response, and reports what came back. It never reads
/// the Session Snapshot, runs Git, or decides what a reference means.
struct ArgusSocketClient {
    let path: String
    let responseTimeout: TimeInterval

    static let socketPathVariable = "ARGUS_SOCKET_PATH"
    static let workspaceIdVariable = "ARGUS_WORKSPACE_ID"

    /// Socket path for this process: the injected path when Argus spawned the
    /// shell, otherwise the app-owned default location.
    static func resolvedPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let injected = environment[socketPathVariable], !injected.isEmpty {
            return injected
        }
        return (ArgusSocketProtocol.defaultSocketPath as NSString).expandingTildeInPath
    }

    func send<Parameters: Codable & Sendable, Payload: Codable & Sendable>(
        _ request: ArgusSocketRequest<Parameters>,
        expecting: Payload.Type
    ) throws -> Payload {
        let descriptor = try connect()
        defer { Darwin.close(descriptor) }
        try write(try frame(request), to: descriptor)
        let response = try decode(try readLine(from: descriptor), as: Payload.self)
        if let failure = response.error {
            throw ArgusCLIError.rejected(code: failure.code, message: failure.message)
        }
        guard let result = response.result else {
            throw ArgusCLIError.malformedResponse("Argus returned a response with no result")
        }
        return result
    }

    private func frame<Parameters: Codable & Sendable>(
        _ request: ArgusSocketRequest<Parameters>
    ) throws -> Data {
        var data = try JSONEncoder().encode(request)
        guard data.count < ArgusSocketProtocol.maximumRequestBytes else {
            throw ArgusCLIError.transport("Request exceeds the maximum frame size")
        }
        data.append(0x0A)
        return data
    }

    private func decode<Payload: Codable & Sendable>(
        _ line: Data,
        as payload: Payload.Type
    ) throws -> ArgusSocketResponse<Payload> {
        do {
            return try JSONDecoder().decode(ArgusSocketResponse<Payload>.self, from: line)
        } catch {
            throw ArgusCLIError.malformedResponse("Argus returned an unreadable response")
        }
    }

    // MARK: - Transport

    private func connect() throws -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8) + [0]
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw ArgusCLIError.transport("Socket path is too long: \(path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: pathBytes)
        }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw ArgusCLIError.transport("Could not create a socket")
        }
        configure(descriptor)

        let length = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, length)
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw Self.connectionError(code)
        }
        return descriptor
    }

    private func configure(_ descriptor: Int32) {
        var noSigPipe: Int32 = 1
        setsockopt(
            descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
            socklen_t(MemoryLayout.size(ofValue: noSigPipe))
        )
        var receiveTimeout = timeval(tv_sec: Int(responseTimeout), tv_usec: 0)
        var sendTimeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(
            descriptor, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        setsockopt(
            descriptor, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
    }

    private static func connectionError(_ code: Int32) -> ArgusCLIError {
        switch code {
        case ENOENT, ECONNREFUSED:
            .applicationUnavailable("Argus is not running")
        case EACCES, EPERM:
            .applicationUnavailable("The Argus socket refused this user")
        default:
            .transport("Could not reach Argus (\(String(cString: strerror(code)))")
        }
    }

    private func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var written = 0
            while written < data.count {
                let sent = Darwin.send(descriptor, base.advanced(by: written), data.count - written, 0)
                guard sent > 0 else {
                    throw ArgusCLIError.transport("Argus closed the connection while reading the request")
                }
                written += sent
            }
        }
    }

    private func readLine(from descriptor: Int32) throws -> Data {
        var buffered = Data()
        var bytes = [UInt8](repeating: 0, count: 8 * 1024)
        while true {
            let received = Darwin.recv(descriptor, &bytes, bytes.count, 0)
            if received == 0 {
                throw ArgusCLIError.transport("Argus closed the connection before responding")
            }
            guard received > 0 else {
                throw errno == EAGAIN || errno == EWOULDBLOCK
                    ? ArgusCLIError.transport("Argus did not respond within \(Int(responseTimeout))s")
                    : ArgusCLIError.transport("Could not read the Argus response")
            }
            buffered.append(contentsOf: bytes.prefix(received))
            if let newline = buffered.firstIndex(of: 0x0A) {
                return buffered.prefix(upTo: newline)
            }
            guard buffered.count <= ArgusSocketProtocol.maximumResponseBytes else {
                throw ArgusCLIError.malformedResponse("Argus response exceeded the maximum size")
            }
        }
    }
}
