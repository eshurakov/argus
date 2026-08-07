import Darwin
import Foundation

extension AgentSocketServer {
    nonisolated static func handle(
        frame: Data,
        deliver: @escaping @MainActor @Sendable (TurnCompletionEvent) -> TurnCompletionDeliveryResult,
        deliverStatus: @escaping @MainActor @Sendable (AgentStatusEvent) -> AgentStatusDeliveryResult
    ) async -> AgentSocketResponse {
        let request: AgentSocketRequest
        do {
            request = try JSONDecoder().decode(AgentSocketRequest.self, from: frame)
        } catch {
            return .failure(id: nil, code: .malformedRequest, message: "Malformed JSON request")
        }

        guard request.version == protocolVersion else {
            return .failure(id: request.id, code: .unsupportedVersion, message: "Unsupported protocol version")
        }
        guard ["agent.turnCompleted", "agent.statusChanged", "agent.statusCleared"].contains(request.method) else {
            return .failure(id: request.id, code: .unknownMethod, message: "Unknown method")
        }
        guard let params = request.params else {
            return .failure(id: request.id, code: .invalidParameters, message: "Missing request parameters")
        }

        switch request.method {
        case "agent.turnCompleted":
            return await handleTurnCompletion(params: params, requestID: request.id, deliver: deliver)
        case "agent.statusChanged", "agent.statusCleared":
            return await handleStatus(
                method: request.method,
                params: params,
                requestID: request.id,
                deliver: deliverStatus
            )
        default:
            return .failure(id: request.id, code: .unknownMethod, message: "Unknown method")
        }
    }

    private nonisolated static func handleTurnCompletion(
        params: AgentSocketParameters,
        requestID: String?,
        deliver: @escaping @MainActor @Sendable (TurnCompletionEvent) -> TurnCompletionDeliveryResult
    ) async -> AgentSocketResponse {
        guard let agentKey = params.agentKey,
            let eventID = params.eventId,
            validBounded(agentKey, maximumLength: 128),
            validBounded(eventID, maximumLength: 512),
            let workspaceID = params.workspaceId.flatMap(UUID.init(uuidString:)),
            let surfaceID = params.surfaceId.flatMap(UUID.init(uuidString:))
        else {
            return .failure(
                id: requestID,
                code: .invalidParameters,
                message: "Invalid turn completion parameters"
            )
        }

        let event = TurnCompletionEvent(
            agentKey: agentKey,
            workspaceId: workspaceID,
            surfaceId: surfaceID,
            eventId: eventID
        )
        let result = await deliver(event)
        switch result {
        case .accepted(let requiresAttention):
            return .success(id: requestID, requiresAttention: requiresAttention)
        case .rejected(let code, let message):
            return .failure(
                id: requestID,
                code: socketErrorCode(for: code),
                message: message + " (\(code.rawValue))"
            )
        }
    }

    private nonisolated static func handleStatus(
        method: String,
        params: AgentSocketParameters,
        requestID: String?,
        deliver: @escaping @MainActor @Sendable (AgentStatusEvent) -> AgentStatusDeliveryResult
    ) async -> AgentSocketResponse {
        let event: AgentStatusEvent
        switch makeStatusEvent(method: method, params: params, requestID: requestID) {
        case .success(let validEvent):
            event = validEvent
        case .failure(let response):
            return response
        }

        let result = await deliver(event)
        switch result {
        case .accepted(let applied):
            return .successStatus(id: requestID, applied: applied)
        case .rejected(let code, let message):
            return .failure(
                id: requestID,
                code: socketErrorCode(for: code),
                message: message + " (\(code.rawValue))"
            )
        }
    }

    private nonisolated static func makeStatusEvent(
        method: String,
        params: AgentSocketParameters,
        requestID: String?
    ) -> AgentSocketResult<AgentStatusEvent> {
        guard let agentKey = params.agentKey,
            let sessionID = params.sessionId,
            validBounded(agentKey, maximumLength: 128),
            validBounded(sessionID, maximumLength: 256),
            let workspaceID = params.workspaceId.flatMap(UUID.init(uuidString:)),
            let sequence = params.sequence,
            sequence > 0
        else {
            return .failure(
                .failure(
                    id: requestID,
                    code: .invalidParameters,
                    message: "Invalid Agent Status parameters"
                )
            )
        }

        let surfaceID: UUID?
        switch statusSurfaceID(from: params, requestID: requestID) {
        case .success(let parsedSurfaceID):
            surfaceID = parsedSurfaceID
        case .failure(let response):
            return .failure(response)
        }

        let state: AgentStatusState?
        switch statusState(method: method, params: params, requestID: requestID) {
        case .success(let parsedState):
            state = parsedState
        case .failure(let response):
            return .failure(response)
        }

        return .success(
            AgentStatusEvent(
                agentKey: agentKey,
                workspaceId: workspaceID,
                surfaceId: surfaceID,
                state: state,
                sessionId: sessionID,
                sequence: sequence
            )
        )
    }

    private nonisolated static func statusSurfaceID(
        from params: AgentSocketParameters,
        requestID: String?
    ) -> AgentSocketResult<UUID?> {
        guard let surface = params.surfaceId else { return .success(nil) }
        guard let surfaceID = UUID(uuidString: surface) else {
            return .failure(
                .failure(
                    id: requestID,
                    code: .invalidParameters,
                    message: "Invalid Agent Status Terminal Surface"
                )
            )
        }
        return .success(surfaceID)
    }

    private nonisolated static func statusState(
        method: String,
        params: AgentSocketParameters,
        requestID: String?
    ) -> AgentSocketResult<AgentStatusState?> {
        guard method == "agent.statusChanged" else { return .success(nil) }
        guard let stateRaw = params.state,
            let state = AgentStatusState(rawValue: stateRaw)
        else {
            return .failure(
                .failure(
                    id: requestID,
                    code: .invalidParameters,
                    message: "Invalid Agent Status state"
                )
            )
        }
        return .success(state)
    }

    private nonisolated static func validBounded(_ value: String?, maximumLength: Int) -> Bool {
        guard let value else { return false }
        return !value.isEmpty && value.utf8.count <= maximumLength
    }

    private nonisolated static func socketErrorCode(for code: TurnCompletionRejectionCode) -> AgentSocketErrorCode {
        switch code {
        case .unknownTerminalSurface: .unknownTerminalSurface
        }
    }

    private nonisolated static func socketErrorCode(for code: AgentStatusRejectionCode) -> AgentSocketErrorCode {
        switch code {
        case .unavailable: .statusUnavailable
        case .unknownWorkspace: .unknownWorkspace
        case .unknownTerminalSurface: .unknownTerminalSurface
        }
    }

    nonisolated static func writeResponse(_ response: AgentSocketResponse, to socket: Int32) {
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

private enum AgentSocketResult<Value> {
    case success(Value)
    case failure(AgentSocketResponse)
}

struct AgentSocketRequest: Decodable {
    let version: Int
    let id: String?
    let method: String
    let params: AgentSocketParameters?
}

struct AgentSocketParameters: Decodable {
    let agentKey: String?
    let workspaceId: String?
    let surfaceId: String?
    let eventId: String?
    let state: String?
    let sessionId: String?
    let sequence: UInt64?
}

struct AgentSocketResponse: Codable {
    let id: String?
    let isSuccessful: Bool
    let result: Result?
    let error: Failure?

    struct Result: Codable {
        let accepted: Bool
        let requiresAttention: Bool?
        let applied: Bool?
    }

    struct Failure: Codable {
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
            id: id,
            isSuccessful: true,
            result: Result(accepted: true, requiresAttention: requiresAttention, applied: nil),
            error: nil
        )
    }

    static func successStatus(id: String?, applied: Bool) -> Self {
        Self(
            id: id,
            isSuccessful: true,
            result: Result(accepted: true, requiresAttention: nil, applied: applied),
            error: nil
        )
    }

    static func failure(id: String?, code: AgentSocketErrorCode, message: String) -> Self {
        Self(id: id, isSuccessful: false, result: nil, error: Failure(code: code, message: message))
    }
}

enum AgentSocketErrorCode: String, Codable {
    case malformedRequest = "malformed_request"
    case unsupportedVersion = "unsupported_version"
    case unknownMethod = "unknown_method"
    case invalidParameters = "invalid_parameters"
    case unknownWorkspace = "unknown_workspace"
    case unknownTerminalSurface = "unknown_terminal_surface"
    case statusUnavailable = "status_unavailable"
    case frameTooLarge = "frame_too_large"
}
