import Foundation

/// Wire contract shared by the Argus Application's Socket Server and the
/// Companion CLI.
///
/// The Companion CLI is transport-only: it encodes requests, decodes
/// responses, and renders them. Every identity decision — resolving a Project
/// or a base Workspace, generating a branch name, validating ownership — is
/// made by the Argus Application, which owns authoritative domain state.
public enum ArgusSocketProtocol {
    /// Version-one newline-delimited JSON framing.
    public static let version = 1

    /// Request-frame ceiling enforced by the Socket Server.
    public static let maximumRequestBytes = 64 * 1024

    /// Response ceiling enforced by clients so a malformed stream cannot grow
    /// unbounded in memory.
    public static let maximumResponseBytes = 4 * 1024 * 1024

    /// Default Socket path when `ARGUS_SOCKET_PATH` is not set.
    public static let defaultSocketPath = "~/.argus/argus.sock"
}

/// Methods implemented by the app-owned Socket Server.
public enum ArgusSocketMethod: String, Codable, Sendable, CaseIterable {
    case agentTurnCompleted = "agent.turnCompleted"
    case agentStatusChanged = "agent.statusChanged"
    case agentStatusCleared = "agent.statusCleared"
    case workspaceList = "workspace.list"
    case workspaceCreate = "workspace.create"
}

/// Structured failure codes carried by Socket Responses.
public enum ArgusSocketErrorCode: String, Codable, Sendable {
    case malformedRequest = "malformed_request"
    case unsupportedVersion = "unsupported_version"
    case unknownMethod = "unknown_method"
    case invalidParameters = "invalid_parameters"
    case unknownWorkspace = "unknown_workspace"
    case unknownTerminalSurface = "unknown_terminal_surface"
    case statusUnavailable = "status_unavailable"
    case frameTooLarge = "frame_too_large"
    case commandUnavailable = "command_unavailable"
    case unknownProject = "unknown_project"
    case ambiguousProject = "ambiguous_project"
    case ambiguousWorkspace = "ambiguous_workspace"
    case invalidBaseWorkspace = "invalid_base_workspace"
    case workspaceLimitReached = "workspace_limit_reached"
    case branchAlreadyExists = "branch_already_exists"
    case workspaceCreationFailed = "workspace_creation_failed"
}

/// One request frame. `method` stays a `String` so an unrecognized method
/// produces `unknown_method` rather than a decoding failure.
public struct ArgusSocketRequest<Parameters: Codable & Sendable>: Codable, Sendable {
    public let version: Int
    public let id: String?
    public let method: String
    public let params: Parameters?

    public init(
        version: Int = ArgusSocketProtocol.version,
        id: String?,
        method: ArgusSocketMethod,
        params: Parameters?
    ) {
        self.version = version
        self.id = id
        self.method = method.rawValue
        self.params = params
    }
}

/// One response frame. `code` stays a `String` so a client built against an
/// older contract can still report an unfamiliar failure.
public struct ArgusSocketResponse<Result: Codable & Sendable>: Codable, Sendable {
    public let id: String?
    public let isSuccessful: Bool
    public let result: Result?
    public let error: Failure?

    public struct Failure: Codable, Sendable {
        public let code: String
        public let message: String

        public init(code: ArgusSocketErrorCode, message: String) {
            self.code = code.rawValue
            self.message = message
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case isSuccessful = "ok"
        case result
        case error
    }

    public init(id: String?, result: Result) {
        self.id = id
        self.isSuccessful = true
        self.result = result
        self.error = nil
    }

    public init(id: String?, code: ArgusSocketErrorCode, message: String) {
        self.id = id
        self.isSuccessful = false
        self.result = nil
        self.error = Failure(code: code, message: message)
    }

    /// Known failure code, when this response carries one this build knows.
    public var errorCode: ArgusSocketErrorCode? {
        error.flatMap { ArgusSocketErrorCode(rawValue: $0.code) }
    }
}
