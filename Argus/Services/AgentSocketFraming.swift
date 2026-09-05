import Foundation

/// MainActor delivery closures the Socket Server routes requests through.
///
/// Bundling them keeps one value flowing from `start()` to the per-client
/// worker threads as method families are added.
struct AgentSocketHandlers: Sendable {
    let deliver: @MainActor @Sendable (TurnCompletionEvent) -> TurnCompletionDeliveryResult
    let deliverStatus: @MainActor @Sendable (AgentStatusEvent) -> AgentStatusDeliveryResult
    let deliverCommand: @MainActor @Sendable (WorkspaceCommandRequest) async -> WorkspaceCommandOutcome
}

/// One encoded Socket Response line, without its newline terminator.
///
/// Method families answer with different result payloads, so the frame is
/// encoded where the payload type is still known and travels back to the
/// client thread as bytes.
struct AgentSocketEncodedResponse: Sendable {
    let data: Data

    init<Value: Encodable>(_ value: Value) {
        if let encoded = try? JSONEncoder().encode(value) {
            data = encoded
        } else {
            data = Self.encodingFailureFrame
        }
    }

    static func success(id: String?, requiresAttention: Bool) -> Self {
        Self(AgentSocketResponse.success(id: id, requiresAttention: requiresAttention))
    }

    static func successStatus(id: String?, applied: Bool) -> Self {
        Self(AgentSocketResponse.successStatus(id: id, applied: applied))
    }

    static func failure(id: String?, code: AgentSocketErrorCode, message: String) -> Self {
        Self(AgentSocketResponse.failure(id: id, code: code, message: message))
    }

    /// Last-resort frame for the impossible case of an unencodable response.
    /// A client must still receive one well-formed line per request.
    private static let encodingFailureFrame = Data(
        """
        {"id":null,"ok":false,"error":{"code":"command_unavailable",\
        "message":"Response could not be encoded"}}
        """.utf8
    )
}
