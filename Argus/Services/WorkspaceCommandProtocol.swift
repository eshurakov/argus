import Foundation

extension AgentSocketServer {
    /// Routes the Companion CLI's Workspace Command methods.
    nonisolated static func handleWorkspaceMethod(
        _ method: ArgusSocketMethod,
        frame: Data,
        requestID: String?,
        handlers: AgentSocketHandlers
    ) async -> AgentSocketEncodedResponse {
        switch method {
        case .workspaceList:
            let outcome = await handlers.deliverCommand(.list)
            guard case .list(let result) = outcome else {
                return rejection(outcome, requestID: requestID, method: method)
            }
            return AgentSocketEncodedResponse(ArgusSocketResponse(id: requestID, result: result))
        case .workspaceCreate:
            guard
                let request = try? JSONDecoder().decode(
                    ArgusSocketRequest<WorkspaceCreateParameters>.self,
                    from: frame
                )
            else {
                return .failure(
                    id: requestID,
                    code: .invalidParameters,
                    message: "Invalid Workspace creation parameters"
                )
            }
            let parameters = request.params ?? WorkspaceCreateParameters()
            let outcome = await handlers.deliverCommand(.create(parameters))
            guard case .created(let result) = outcome else {
                return rejection(outcome, requestID: requestID, method: method)
            }
            return AgentSocketEncodedResponse(ArgusSocketResponse(id: requestID, result: result))
        case .agentTurnCompleted, .agentStatusChanged, .agentStatusCleared:
            return .failure(id: requestID, code: .unknownMethod, message: "Unknown method")
        }
    }

    private nonisolated static func rejection(
        _ outcome: WorkspaceCommandOutcome,
        requestID: String?,
        method: ArgusSocketMethod
    ) -> AgentSocketEncodedResponse {
        guard case .rejected(let code, let message) = outcome else {
            return .failure(
                id: requestID,
                code: .commandUnavailable,
                message: "\(method.rawValue) produced an unexpected result"
            )
        }
        return .failure(id: requestID, code: code, message: message)
    }
}
