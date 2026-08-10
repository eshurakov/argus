import CryptoKit
import Foundation
import Testing

@testable import Argus

struct PiIntegrationServiceTests {
    @Test
    func resolvesTheConfiguredPiAgentDirectory() throws {
        try withFixture { fixture in
            let alternate = fixture.root.appendingPathComponent("custom-pi-agent")
            let service = fixture.service(
                environment: ["PI_CODING_AGENT_DIR": alternate.path], homeDirectory: fixture.root)
            let paths = try service.resolvedPaths()

            #expect(paths.agentDirectory.path.hasSuffix("custom-pi-agent"))
            #expect(paths.extensionFile.lastPathComponent == PiIntegrationService.extensionFileName)
            #expect(paths.extensionFile.path.contains("extensions"))
        }
    }

    @Test
    func enableAndDisableOwnOnlyTheArgusExtension() throws {
        try withFixture { fixture in
            let service = fixture.service()
            let paths = try service.enable()

            #expect(FileManager.default.fileExists(atPath: paths.extensionFile.path))
            #expect(service.isInstalled(at: paths))

            _ = try service.enable()
            #expect(service.isInstalled(at: paths))

            _ = try service.disable()
            #expect(!FileManager.default.fileExists(atPath: paths.extensionFile.path))
            #expect(FileManager.default.fileExists(atPath: paths.lockFile.path))
        }
    }

    @Test
    func historicalArgusExtensionIsUpgradedAndRemoved() throws {
        try withFixture { fixture in
            let historicalPlugin = Data(
                "/* Historical Argus Pi extension */\nexport default {}\n".utf8
            )
            let service = fixture.service(historicalPluginPayload: historicalPlugin)
            let paths = try service.resolvedPaths()
            try FileManager.default.createDirectory(
                at: paths.extensionDirectory,
                withIntermediateDirectories: true
            )
            try historicalPlugin.write(to: paths.extensionFile)

            #expect(!service.isInstalled(at: paths))
            _ = try service.enable()
            #expect(try Data(contentsOf: paths.extensionFile) == Data(contentsOf: fixture.plugin))

            try historicalPlugin.write(to: paths.extensionFile)
            _ = try service.disable()
            #expect(!FileManager.default.fileExists(atPath: paths.extensionFile.path))
        }
    }

    @Test
    func missingPluginResourceDoesNotCreateManagedArtifacts() throws {
        try withFixture { fixture in
            let agentDirectory = fixture.root.appendingPathComponent("missing-resource-agent")
            let service = PiIntegrationService(
                environment: ["PI_CODING_AGENT_DIR": agentDirectory.path],
                homeDirectory: fixture.root,
                extensionSourceURL: nil
            )
            let paths = try service.resolvedPaths()

            #expect(throws: PiIntegrationError.self) { try service.enable() }
            #expect(!FileManager.default.fileExists(atPath: paths.agentDirectory.path))
        }
    }

    @Test
    func unownedExtensionIsNeverReplacedOrRemoved() throws {
        try withFixture { fixture in
            let service = fixture.service()
            let paths = try service.resolvedPaths()
            try FileManager.default.createDirectory(
                at: paths.extensionDirectory,
                withIntermediateDirectories: true
            )
            try Data("user extension".utf8).write(to: paths.extensionFile)

            #expect(throws: PiIntegrationError.self) { try service.enable() }
            #expect(throws: PiIntegrationError.self) { try service.disable() }
            #expect(try Data(contentsOf: paths.extensionFile) == Data("user extension".utf8))
        }
    }

    @Test
    func disableWithoutAnInstalledExtensionDoesNotCreatePiFiles() throws {
        try withFixture { fixture in
            let service = fixture.service()
            let paths = try service.disable()

            #expect(!FileManager.default.fileExists(atPath: paths.agentDirectory.path))
            #expect(!FileManager.default.fileExists(atPath: paths.extensionFile.path))
        }
    }

    @Test
    func pluginResourceExistsForInstallation() throws {
        try withFixture { fixture in
            #expect(FileManager.default.fileExists(atPath: fixture.plugin.path))
        }
    }

    @Test
    func pluginBehavioralHarnessPasses() throws {
        let repositoryRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let harness = repositoryRoot.appendingPathComponent(
            "Tests/PiIntegrationTests/pi-plugin-events.mjs"
        )
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = ["node", harness.path]
        process.currentDirectoryURL = repositoryRoot
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        try process.run()
        process.waitUntilExit()

        let result =
            String(
                bytes: output.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
        #expect(process.terminationStatus == 0, "pi-plugin-events.mjs failed: \(result)")
    }

    private func withFixture(_ body: (Fixture) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("argus-pi-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = root.appendingPathComponent("source.js")
        try "/* Argus-owned Pi extension */\nexport default function () {}\n"
            .write(to: plugin, atomically: true, encoding: .utf8)
        try body(Fixture(root: root, plugin: plugin))
    }

    private struct Fixture {
        let root: URL
        let plugin: URL

        func service(
            environment: [String: String] = [:],
            homeDirectory: URL? = nil,
            historicalPluginPayload: Data? = nil
        ) -> PiIntegrationService {
            var environment = environment
            if environment["PI_CODING_AGENT_DIR"] == nil {
                environment["PI_CODING_AGENT_DIR"] = root.appendingPathComponent("agent").path
            }
            let acceptedDigests =
                historicalPluginPayload.map {
                    Set([Data(SHA256.hash(data: $0))])
                } ?? []
            return PiIntegrationService(
                environment: environment,
                homeDirectory: homeDirectory ?? root,
                extensionSourceURL: plugin,
                acceptedHistoricalPluginDigests: acceptedDigests
            )
        }
    }
}
