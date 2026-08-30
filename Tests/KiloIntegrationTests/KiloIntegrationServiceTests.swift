import Foundation
import Testing

@testable import Argus

struct KiloIntegrationServiceTests {
    private let declaration = KiloIntegrationService.pluginDeclaration

    @Test
    func enablesJSONCWithCommentsTrailingCommaAndExistingPlugins() throws {
        try withFixture { fixture in
            try fixture.write(
                """
                // Kilo config
                {
                  "theme": "dark",
                  "plugin": [
                    "user.js", // retained
                  ],
                }
                """, named: "tui.jsonc")
            let paths = try fixture.service().enable()
            let text = try String(contentsOf: paths.configFile, encoding: .utf8)
            #expect(text.contains("// Kilo config"))
            #expect(text.contains("\"user.js\""))
            #expect(text.contains("\"plugins/argus-turn-completed.js\""))
            #expect(FileManager.default.fileExists(atPath: paths.pluginFile.path))
        }
    }

    @Test
    func enablesJSONCWhoseRootObjectHasATrailingComma() throws {
        try withFixture { fixture in
            try fixture.write("{\n  \"theme\": \"dark\",\n}\n", named: "tui.jsonc")

            let paths = try fixture.service().enable()
            let text = try String(contentsOf: paths.configFile, encoding: .utf8)

            #expect(text.contains("\"theme\": \"dark\","))
            #expect(text.contains("\"plugin\": [\"plugins/argus-turn-completed.js\"],"))
            _ = try JSONCEditor.edit(text, declaration: declaration, operation: .disable)
        }
    }

    @Test
    func disableWithoutManagedArtifactsDoesNotCreateKiloConfiguration() throws {
        try withFixture { fixture in
            let paths = try fixture.service().disable()

            #expect(!FileManager.default.fileExists(atPath: paths.configFile.path))
            #expect(!FileManager.default.fileExists(atPath: paths.pluginFile.path))
            #expect(!FileManager.default.fileExists(atPath: paths.lockFile.path))
        }
    }

    @Test
    func repeatedEnableIsIdempotentAndDisablePreservesUserPlugin() throws {
        try withFixture { fixture in
            try fixture.write("{\n  \"plugin\": [\"user.js\"]\n}\n", named: "tui.json")
            let service = fixture.service()
            let paths = try service.enable()
            _ = try service.enable()
            let enabled = try String(contentsOf: paths.configFile, encoding: .utf8)
            #expect(enabled.components(separatedBy: declaration).count == 2)
            _ = try service.disable()
            let disabled = try String(contentsOf: paths.configFile, encoding: .utf8)
            #expect(disabled.contains("user.js"))
            #expect(!disabled.contains(declaration))
            #expect(!FileManager.default.fileExists(atPath: paths.pluginFile.path))
        }
    }

    @Test
    func jsoncWinsWhenBothConfigFilesExist() throws {
        try withFixture { fixture in
            try fixture.write("{}", named: "tui.json")
            try fixture.write("// preferred\n{}", named: "tui.jsonc")
            let paths = try fixture.service().enable()
            #expect(paths.configFile.lastPathComponent == "tui.jsonc")
            #expect(
                !(try String(contentsOf: fixture.root.appendingPathComponent("tui.json"), encoding: .utf8))
                    .contains(declaration))
        }
    }

    @Test
    func malformedConfigurationAndInjectedFailureLeaveArtifactsUntouched() throws {
        try withFixture { fixture in
            try fixture.write("{ invalid", named: "tui.jsonc")
            #expect(throws: JSONCEditor.Error.self) { try fixture.service().enable() }
            #expect(
                try String(contentsOf: fixture.root.appendingPathComponent("tui.jsonc"), encoding: .utf8) == "{ invalid"
            )

            try fixture.write("{}", named: "tui.jsonc")
            let service = fixture.service { point in if point == .stageConfig { throw FixtureError.injected } }
            #expect(throws: FixtureError.self) { try service.enable() }
            #expect(try String(contentsOf: fixture.root.appendingPathComponent("tui.jsonc"), encoding: .utf8) == "{}")
            #expect(
                !FileManager.default.fileExists(
                    atPath: fixture.root.appendingPathComponent("plugins/argus-turn-completed.js").path))
        }
    }
}

extension KiloIntegrationServiceTests {
    @Test(arguments: ["01", "-01", "+1", ".5", "1.", "NaN", "Infinity", "1e", "1e+", "-"])
    fileprivate func invalidNumbersLeaveConfigurationAndPluginUntouched(_ number: String) throws {
        try withFixture { fixture in
            let original = "{\"plugin\": [\"\(declaration)\"], \"value\": \(number)}"
            let service = fixture.service()
            let paths = try service.resolvedPaths()
            try fixture.write(original, named: "tui.jsonc")

            #expect(throws: JSONCEditor.Error.self) { try service.enable() }
            #expect(try String(contentsOf: paths.configFile, encoding: .utf8) == original)
            #expect(!FileManager.default.fileExists(atPath: paths.pluginFile.path))

            try FileManager.default.createDirectory(
                at: paths.pluginFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: fixture.plugin, to: paths.pluginFile)
            #expect(throws: JSONCEditor.Error.self) { try service.disable() }
            #expect(try String(contentsOf: paths.configFile, encoding: .utf8) == original)
            #expect(try Data(contentsOf: paths.pluginFile) == Data(contentsOf: fixture.plugin))
        }
    }

    @Test(arguments: ["0", "-0", "1", "-42", "0.5", "-12.34", "1e10", "1E+10", "-1.2e-3"])
    fileprivate func validJSONNumbersSupportEnableAndDisable(_ number: String) throws {
        try withFixture { fixture in
            try fixture.write("{\"value\": \(number)}", named: "tui.jsonc")
            let service = fixture.service()
            let paths = try service.enable()
            #expect(service.isInstalled(at: paths))

            _ = try service.disable()
            let text = try String(contentsOf: paths.configFile, encoding: .utf8)
            #expect(text.contains("\"value\": \(number)"))
            #expect(!text.contains(declaration))
            #expect(!FileManager.default.fileExists(atPath: paths.pluginFile.path))
        }
    }

    @Test(arguments: ["1/* retained */", "true// retained\n", "null/* retained */"])
    fileprivate func adjacentScalarCommentsSupportEnableAndDisable(_ scalar: String) throws {
        try withFixture { fixture in
            try fixture.write("{\"value\": \(scalar)}", named: "tui.jsonc")
            let service = fixture.service()
            let paths = try service.enable()
            #expect(service.isInstalled(at: paths))

            _ = try service.disable()
            let text = try String(contentsOf: paths.configFile, encoding: .utf8)
            #expect(text.contains(scalar))
            #expect(!text.contains(declaration))
            #expect(!FileManager.default.fileExists(atPath: paths.pluginFile.path))
        }
    }

    @Test(arguments: ["/*", "/* unterminated comment"])
    fileprivate func unterminatedBlockCommentsAfterRootLeaveArtifactsUntouched(_ comment: String) throws {
        try withFixture { fixture in
            let original = "{\"plugin\": [\"\(declaration)\"]} \(comment)"
            let service = fixture.service()
            let paths = try service.resolvedPaths()
            try fixture.write(original, named: "tui.jsonc")

            #expect(throws: JSONCEditor.Error.self) { try service.enable() }
            #expect(try String(contentsOf: paths.configFile, encoding: .utf8) == original)
            #expect(!FileManager.default.fileExists(atPath: paths.pluginFile.path))

            try FileManager.default.createDirectory(
                at: paths.pluginFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: fixture.plugin, to: paths.pluginFile)
            #expect(throws: JSONCEditor.Error.self) { try service.disable() }
            #expect(try String(contentsOf: paths.configFile, encoding: .utf8) == original)
            #expect(try Data(contentsOf: paths.pluginFile) == Data(contentsOf: fixture.plugin))
        }
    }

    @Test
    fileprivate func unownedPluginIsNeverReplacedOrRemoved() throws {
        try withFixture { fixture in
            try fixture.write("{\"plugin\": [\"plugins/argus-turn-completed.js\"]}", named: "tui.jsonc")
            let plugin = fixture.root.appendingPathComponent("plugins/argus-turn-completed.js")
            try FileManager.default.createDirectory(
                at: plugin.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "user artifact".write(to: plugin, atomically: true, encoding: .utf8)
            #expect(throws: KiloIntegrationError.self) { try fixture.service().enable() }
            #expect(throws: KiloIntegrationError.self) { try fixture.service().disable() }
            #expect(try String(contentsOf: plugin, encoding: .utf8) == "user artifact")
        }
    }

    @Test(arguments: ["// comment, before managed entry", "/* block comment, before managed entry */"])
    fileprivate func disableRemovesFinalPluginUsingStructuralComma(_ comment: String) throws {
        try withFixture { fixture in
            try fixture.write(
                """
                {
                  "plugin": [
                    "user.js",
                    \(comment)
                    "plugins/argus-turn-completed.js"
                  ]
                }
                """, named: "tui.jsonc")
            let service = fixture.service()
            let paths = try service.disable()
            let text = try String(contentsOf: paths.configFile, encoding: .utf8)
            #expect(text.contains("user.js"))
            #expect(text.contains(comment))
            #expect(!text.contains(declaration))
            _ = try JSONCEditor.edit(text, declaration: declaration, operation: .enable)
        }
    }

    @Test(arguments: ["// comment, before inserted entry", "/* block comment, before inserted entry */"])
    fileprivate func enablePreservesCommentsContainingCommasBeforeManagedEntry(_ comment: String) throws {
        try withFixture { fixture in
            try fixture.write(
                """
                {
                  "plugin": [
                    "user.js",
                    \(comment)
                  ]
                }
                """, named: "tui.jsonc")
            let paths = try fixture.service().enable()
            let text = try String(contentsOf: paths.configFile, encoding: .utf8)
            #expect(text.contains(comment))
            #expect(try JSONCEditor.containsDeclaration(declaration, in: text))
        }
    }

    @Test
    fileprivate func supportsEscapedUnicodeAndSurrogatePairsInPluginConfiguration() throws {
        try withFixture { fixture in
            try fixture.write(
                """
                {
                  "label\\u0020name": "\\uD83D\\uDE80",
                  "plugin": ["plugins/\\u0061rgus-turn-completed.js", "\\u03A9.js"]
                }
                """, named: "tui.jsonc")
            let service = fixture.service()
            let paths = try service.enable()
            #expect(service.isInstalled(at: paths))
            _ = try service.disable()
            let text = try String(contentsOf: paths.configFile, encoding: .utf8)
            #expect(text.contains("\\uD83D\\uDE80"))
            #expect(text.contains("\\u03A9.js"))
            #expect(!(try JSONCEditor.containsDeclaration(declaration, in: text)))
        }
    }

    @Test(arguments: ["\\uD83D", "\\uDE80", "\\u12G4", "\\uD83D\\u0041"])
    fileprivate func rejectsInvalidUnicodeEscapes(_ escaped: String) {
        #expect(throws: JSONCEditor.Error.self) {
            try JSONCEditor.edit("{\"plugin\": [\"\(escaped)\"]}", declaration: declaration, operation: .enable)
        }
    }

    @Test
    fileprivate func markerPrefixedPluginIsNotOwnedOnEnableOrDisable() throws {
        try withFixture { fixture in
            try fixture.write("{\"plugin\": [\"plugins/argus-turn-completed.js\"]}", named: "tui.jsonc")
            let plugin = fixture.root.appendingPathComponent("plugins/argus-turn-completed.js")
            try FileManager.default.createDirectory(
                at: plugin.deletingLastPathComponent(), withIntermediateDirectories: true)
            let unowned = "/* Argus-owned Kilo TUI plugin */\nuser modified artifact\n"
            try unowned.write(to: plugin, atomically: true, encoding: .utf8)
            let service = fixture.service()
            #expect(!service.isInstalled(at: try service.resolvedPaths()))
            #expect(throws: KiloIntegrationError.self) { try service.enable() }
            #expect(throws: KiloIntegrationError.self) { try service.disable() }
            #expect(try String(contentsOf: plugin, encoding: .utf8) == unowned)
        }
    }

    @Test
    fileprivate func environmentOverrideAndNewConfigUseKiloDirectory() throws {
        try withFixture { fixture in
            let alternate = fixture.root.appendingPathComponent("alternate")
            let paths = try fixture.service(environment: ["KILO_CONFIG_DIR": alternate.path]).enable()
            #expect(paths.configFile == alternate.appendingPathComponent("tui.jsonc"))
        }
    }

    @Test
    fileprivate func injectedLockFailureDoesNotCreateManagedArtifacts() throws {
        try withFixture { fixture in
            let service = fixture.service { point in if point == .lock { throw FixtureError.injected } }
            #expect(throws: FixtureError.self) { try service.enable() }
            #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("tui.jsonc").path))
            #expect(
                !FileManager.default.fileExists(
                    atPath: fixture.root.appendingPathComponent("plugins/argus-turn-completed.js").path))
        }
    }

    // Public Kilo event schemas cannot distinguish an ordinary programmatic,
    // non-synthetic user message from a human-authored prompt; plugin filtering is best effort.
    @Test
    fileprivate func pluginResourceExistsForInstallation() throws {
        try withFixture { fixture in
            #expect(FileManager.default.fileExists(atPath: fixture.plugin.path))
        }
    }

}

extension KiloIntegrationServiceTests {
    @Test
    fileprivate func pluginBehavioralHarnessPasses() throws {
        let repositoryRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let harness = repositoryRoot.appendingPathComponent("Tests/KiloIntegrationTests/plugin-events.mjs")
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = ["node", harness.path]
        process.currentDirectoryURL = repositoryRoot
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        try process.run()
        process.waitUntilExit()

        let result = String(bytes: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(process.terminationStatus == 0, "plugin-events.mjs failed: \(result)")
    }
}

private enum FixtureError: Error { case injected }

private struct Fixture {
    let root: URL
    let plugin: URL
    func write(_ text: String, named: String) throws {
        try text.write(to: root.appendingPathComponent(named), atomically: true, encoding: .utf8)
    }
    func service(environment: [String: String] = [:], inject: ((KiloIntegrationFailurePoint) throws -> Void)? = nil)
        -> KiloIntegrationService
    {
        var environment = environment
        if environment["KILO_CONFIG_DIR"] == nil {
            environment["KILO_CONFIG_DIR"] = root.path
        }
        return KiloIntegrationService(
            environment: environment, homeDirectory: root.deletingLastPathComponent(), pluginSourceURL: plugin,
            injectFailure: inject)
    }
}

private func withFixture(_ body: (Fixture) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("argus-kilo-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let plugin = root.appendingPathComponent("source.js")
    try "/* Argus-owned Kilo TUI plugin */\nexport default {};\n".write(to: plugin, atomically: true, encoding: .utf8)
    try body(Fixture(root: root, plugin: plugin))
}
