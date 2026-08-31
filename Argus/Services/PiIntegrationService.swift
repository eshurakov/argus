import Combine
import CryptoKit
import Darwin
import Foundation

enum PiIntegrationError: LocalizedError {
    case pluginResourceUnavailable
    case pluginFileNotOwned(URL)
    case lockFailed(String)

    var errorDescription: String? {
        switch self {
        case .pluginResourceUnavailable:
            "The bundled Pi extension could not be found."
        case .pluginFileNotOwned(let url):
            "Refusing to replace an extension not owned by Argus: \(url.path)"
        case .lockFailed(let detail):
            "Could not lock Pi integration files: \(detail)"
        }
    }
}

@MainActor
final class PiIntegrationModel: ObservableObject {
    enum Status: Equatable {
        case unavailable
        case installed
        case busy
        case failed(String)
    }

    @Published private(set) var status: Status = .unavailable
    @Published private(set) var managedExtensionPath = ""

    private let service: PiIntegrationService

    init(service: PiIntegrationService = PiIntegrationService()) {
        self.service = service
        refresh()
    }

    func refresh() {
        do {
            let paths = try service.resolvedPaths()
            managedExtensionPath = paths.extensionFile.path
            status = service.isInstalled(at: paths) ? .installed : .unavailable
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func enable() { update(.enable) }
    func disable() { update(.disable) }

    private func update(_ operation: PiIntegrationOperation) {
        status = .busy
        Task {
            do {
                let paths = try await Task.detached(priority: .userInitiated) {
                    try operation == .enable ? self.service.enable() : self.service.disable()
                }.value
                managedExtensionPath = paths.extensionFile.path
                status = operation == .enable ? .installed : .unavailable
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }
}

private enum PiIntegrationOperation: Sendable { case enable, disable }

/// Installs only Argus's Pi Agent Status and turn-completion extension.
final class PiIntegrationService: @unchecked Sendable {
    static let extensionFileName = "argus-agent-status.js"

    // Complete-file digests for Argus-managed extensions from previous versions.
    private static let historicalPluginDigests: Set<Data> = [
        // Live Agent Status-only extension from before Pi turn-completion support.
        Data([
            0x8f, 0x43, 0x1f, 0xc3, 0x1f, 0xc3, 0x07, 0x1f,
            0x2b, 0x4d, 0x93, 0x6d, 0xd5, 0x8c, 0xac, 0x30,
            0x56, 0x3c, 0x8c, 0xc5, 0xef, 0x02, 0x70, 0xf9,
            0xd2, 0x30, 0x4e, 0x57, 0xc3, 0xff, 0x26, 0xdd
        ]),
        // Argus 1.13.0 Agent Status and turn-completion extension.
        Data([
            0xf1, 0xd5, 0x02, 0x4d, 0x61, 0x36, 0xad, 0x32,
            0xc0, 0x0e, 0xd8, 0xc1, 0xce, 0x7e, 0xbb, 0xb5,
            0x89, 0xb2, 0x91, 0x05, 0x9c, 0x82, 0xf7, 0x78,
            0xed, 0x0f, 0xd3, 0x5d, 0xde, 0xd1, 0x97, 0x9f
        ])
    ]

    let environment: [String: String]
    let homeDirectory: URL
    let extensionSourceURL: URL?
    private let fileManager: FileManager
    private let acceptedHistoricalPluginDigests: Set<Data>

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        extensionSourceURL: URL? = Bundle.main.url(
            forResource: "ArgusPiAgentStatusPlugin",
            withExtension: "js"
        ),
        fileManager: FileManager = .default,
        acceptedHistoricalPluginDigests: Set<Data> = PiIntegrationService.historicalPluginDigests
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.extensionSourceURL = extensionSourceURL
        self.fileManager = fileManager
        self.acceptedHistoricalPluginDigests = acceptedHistoricalPluginDigests
    }

    struct Paths: Equatable {
        let agentDirectory: URL
        let extensionDirectory: URL
        let extensionFile: URL
        let lockFile: URL
    }

    func resolvedPaths() throws -> Paths {
        let agentDirectory: URL
        if let override = environment["PI_CODING_AGENT_DIR"], !override.isEmpty {
            agentDirectory = URL(
                fileURLWithPath: (override as NSString).expandingTildeInPath,
                isDirectory: true
            )
        } else {
            agentDirectory = homeDirectory.appendingPathComponent(".pi/agent", isDirectory: true)
        }
        let extensionDirectory = agentDirectory.appendingPathComponent("extensions", isDirectory: true)
        return Paths(
            agentDirectory: agentDirectory,
            extensionDirectory: extensionDirectory,
            extensionFile: extensionDirectory.appendingPathComponent(Self.extensionFileName),
            lockFile: agentDirectory.appendingPathComponent(".argus-pi-integration.lock")
        )
    }

    func enable() throws -> Paths { try update(.enable) }
    func disable() throws -> Paths { try update(.disable) }

    func isInstalled(at paths: Paths) -> Bool {
        guard let installed = try? Data(contentsOf: paths.extensionFile),
            let expected = try? pluginData()
        else { return false }
        return installed == expected
    }

    private enum Update: Equatable { case enable, disable }

    private func update(_ update: Update) throws -> Paths {
        let paths = try resolvedPaths()
        let existing = fileManager.fileExists(atPath: paths.extensionFile.path)
        if update == .disable, !existing {
            return paths
        }

        // Read the bundled bytes before creating any managed files. A missing
        // resource must not leave behind an Argus directory or lock file.
        let expectedPluginData = try pluginData()
        return try updateLocked(update, paths: paths, expectedPluginData: expectedPluginData)
    }

    private func updateLocked(
        _ update: Update,
        paths: Paths,
        expectedPluginData: Data
    ) throws -> Paths {
        try fileManager.createDirectory(at: paths.agentDirectory, withIntermediateDirectories: true)
        let descriptor = open(paths.lockFile.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw PiIntegrationError.lockFailed(String(cString: strerror(errno)))
        }
        defer { close(descriptor) }
        try acquireIntegrationLock(descriptor)
        defer { flock(descriptor, LOCK_UN) }

        let existing = try existingData(at: paths.extensionFile)
        if let existing, !isOwned(existing, currentPluginData: expectedPluginData) {
            throw PiIntegrationError.pluginFileNotOwned(paths.extensionFile)
        }

        switch update {
        case .enable:
            try atomicWrite(expectedPluginData, to: paths.extensionFile)
        case .disable:
            if existing != nil {
                try fileManager.removeItem(at: paths.extensionFile)
            }
        }
        return paths
    }

    private func acquireIntegrationLock(_ descriptor: Int32) throws {
        let deadline = Date().addingTimeInterval(2)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN else {
                throw PiIntegrationError.lockFailed(String(cString: strerror(errno)))
            }
            guard !Task.isCancelled, Date() < deadline else {
                throw PiIntegrationError.lockFailed("Timed out waiting for the integration lock")
            }
            usleep(50_000)
        }
    }

    private func existingData(at url: URL) throws -> Data? {
        fileManager.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
    }

    private func isOwned(_ data: Data, currentPluginData: Data) -> Bool {
        data == currentPluginData
            || acceptedHistoricalPluginDigests.contains(Data(SHA256.hash(data: data)))
    }

    private func pluginData() throws -> Data {
        guard let source = extensionSourceURL else {
            throw PiIntegrationError.pluginResourceUnavailable
        }
        return try Data(contentsOf: source)
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporary = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )
        try data.write(to: temporary, options: .atomic)
        defer { try? fileManager.removeItem(at: temporary) }
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(
                url,
                withItemAt: temporary,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: temporary, to: url)
        }
    }
}
