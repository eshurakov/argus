import Combine
import Darwin
import Foundation

enum KiloIntegrationError: LocalizedError {
    case pluginResourceUnavailable
    case pluginFileNotOwned(URL)
    case lockFailed(String)
    case invalidConfiguration(String)

    var errorDescription: String? {
        switch self {
        case .pluginResourceUnavailable: "The bundled Kilo plugin could not be found."
        case .pluginFileNotOwned(let url): "Refusing to replace a plugin not owned by Argus: \(url.path)"
        case .lockFailed(let detail): "Could not lock Kilo configuration: \(detail)"
        case .invalidConfiguration(let detail): "Kilo configuration validation failed: \(detail)"
        }
    }
}

enum KiloIntegrationFailurePoint { case lock, stagePlugin, stageConfig, replacePlugin, replaceConfig }

@MainActor
final class KiloIntegrationModel: ObservableObject {
    enum Status: Equatable {
        case unavailable
        case installed
        case busy
        case failed(String)
    }

    @Published private(set) var status: Status = .unavailable
    @Published private(set) var managedConfigPath = ""

    private let service: KiloIntegrationService

    init(service: KiloIntegrationService = KiloIntegrationService()) {
        self.service = service
        refresh()
    }

    func refresh() {
        do {
            let paths = try service.resolvedPaths()
            managedConfigPath = paths.configFile.path
            status = service.isInstalled(at: paths) ? .installed : .unavailable
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func enable() { update(.enable) }
    func disable() { update(.disable) }

    private func update(_ operation: KiloIntegrationOperation) {
        status = .busy
        Task { @MainActor in
            do {
                let paths = try operation == .enable ? service.enable() : service.disable()
                managedConfigPath = paths.configFile.path
                status = operation == .enable ? .installed : .unavailable
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }
}

private enum KiloIntegrationOperation { case enable, disable }

/// Installs only Argus's local Kilo TUI plugin. UI wiring intentionally lives elsewhere.
final class KiloIntegrationService {
    static let pluginFileName = "argus-turn-completed.js"
    static let pluginDeclaration = "plugins/\(pluginFileName)"

    let environment: [String: String]
    let homeDirectory: URL
    let pluginSourceURL: URL?
    private let fileManager: FileManager
    private let injectFailure: ((KiloIntegrationFailurePoint) throws -> Void)?

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        pluginSourceURL: URL? = Bundle.main.url(forResource: "ArgusKiloTurnCompletionPlugin", withExtension: "js"),
        fileManager: FileManager = .default,
        injectFailure: ((KiloIntegrationFailurePoint) throws -> Void)? = nil
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.pluginSourceURL = pluginSourceURL
        self.fileManager = fileManager
        self.injectFailure = injectFailure
    }

    struct Paths: Equatable {
        let configDirectory: URL
        let configFile: URL
        let pluginFile: URL
        let lockFile: URL
    }

    func resolvedPaths(createConfigIfMissing: Bool = false) throws -> Paths {
        let directory: URL
        if let override = environment["KILO_CONFIG_DIR"], !override.isEmpty {
            directory = URL(fileURLWithPath: override, isDirectory: true)
        } else if let override = environment["OPENCODE_CONFIG_DIR"], !override.isEmpty {
            directory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            directory = homeDirectory.appendingPathComponent(".config/kilo", isDirectory: true)
        }
        let jsonc = directory.appendingPathComponent("tui.jsonc")
        let json = directory.appendingPathComponent("tui.json")
        let config =
            fileManager.fileExists(atPath: jsonc.path)
            ? jsonc : (fileManager.fileExists(atPath: json.path) ? json : jsonc)
        return Paths(
            configDirectory: directory, configFile: config,
            pluginFile: directory.appendingPathComponent("plugins/\(Self.pluginFileName)"),
            lockFile: directory.appendingPathComponent(".argus-kilo-integration.lock"))
    }

    func enable() throws -> Paths { try update(.enable) }
    func disable() throws -> Paths { try update(.disable) }

    private enum Update { case enable, disable }
    private func update(_ update: Update) throws -> Paths {
        let paths = try resolvedPaths(createConfigIfMissing: update == .enable)
        if update == .disable,
            !fileManager.fileExists(atPath: paths.configFile.path),
            !fileManager.fileExists(atPath: paths.pluginFile.path)
        {
            return paths
        }
        return try updateLocked(update, paths: paths)
    }

    private func updateLocked(_ update: Update, paths: Paths) throws -> Paths {
        try fileManager.createDirectory(at: paths.configDirectory, withIntermediateDirectories: true)
        let descriptor = open(paths.lockFile.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw KiloIntegrationError.lockFailed(String(cString: strerror(errno))) }
        defer { close(descriptor) }
        try injectFailure?(.lock)
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw KiloIntegrationError.lockFailed(String(cString: strerror(errno)))
        }
        defer { flock(descriptor, LOCK_UN) }

        let originalConfig = try existingData(at: paths.configFile)
        let originalPlugin = try existingData(at: paths.pluginFile)
        if let originalPlugin, !(try isOwnedPlugin(originalPlugin)) {
            throw KiloIntegrationError.pluginFileNotOwned(paths.pluginFile)
        }
        let originalText = originalConfig.flatMap { String(data: $0, encoding: .utf8) } ?? "{}\n"
        guard originalConfig == nil || String(data: originalConfig!, encoding: .utf8) != nil else {
            throw KiloIntegrationError.invalidConfiguration("not UTF-8")
        }
        let edited = try JSONCEditor.edit(
            originalText, declaration: Self.pluginDeclaration, operation: update == .enable ? .enable : .disable)
        // Structural validation.
        _ = try JSONCEditor.edit(edited, declaration: Self.pluginDeclaration, operation: .disable)

        do {
            if update == .enable {
                let plugin = try pluginData()
                try injectFailure?(.stagePlugin)
                try stage(plugin, for: paths.pluginFile)
            }
            try injectFailure?(.stageConfig)
            try stage(Data(edited.utf8), for: paths.configFile)
            if update == .enable {
                try injectFailure?(.replacePlugin)
                try atomicWrite(pluginData(), to: paths.pluginFile)
            }
            try injectFailure?(.replaceConfig)
            try atomicWrite(Data(edited.utf8), to: paths.configFile)
            if update == .disable, originalPlugin != nil {
                try fileManager.removeItem(at: paths.pluginFile)
            }
        } catch {
            try? restore(originalConfig, to: paths.configFile)
            try? restore(originalPlugin, to: paths.pluginFile)
            throw error
        }
        return paths
    }

    func isInstalled(at paths: Paths) -> Bool {
        guard let config = try? String(contentsOf: paths.configFile),
            let plugin = try? Data(contentsOf: paths.pluginFile)
        else { return false }
        return (try? JSONCEditor.containsDeclaration(Self.pluginDeclaration, in: config)) == true
            && (try? isOwnedPlugin(plugin)) == true
    }

    private func existingData(at url: URL) throws -> Data? {
        fileManager.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
    }
    private func atomicWrite(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporary, backupItemName: nil, options: [])
        } else {
            try fileManager.moveItem(at: temporary, to: url)
        }
    }
    private func stage(_ data: Data, for url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stageURL = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).stage")
        try data.write(to: stageURL, options: .atomic)
        try? fileManager.removeItem(at: stageURL)
    }
    private func pluginData() throws -> Data {
        guard let source = pluginSourceURL else { throw KiloIntegrationError.pluginResourceUnavailable }
        return try Data(contentsOf: source)
    }
    private func restore(_ data: Data?, to url: URL) throws {
        if let data {
            try atomicWrite(data, to: url)
        } else if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }
    private func isOwnedPlugin(_ data: Data) throws -> Bool {
        let expectedPlugin = try pluginData()
        return data == expectedPlugin
    }
}
