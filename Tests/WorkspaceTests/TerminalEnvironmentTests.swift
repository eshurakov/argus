import Foundation
import Testing

@testable import Argus

@Suite
struct TerminalEnvironmentTests {
    @Test
    func spawnedShellsReceiveTheArgusIdentityVariables() {
        let workspaceId = UUID()
        let surfaceId = UUID()

        let environment = TerminalEnvironment.variables(
            socketPath: "/Users/tester/.argus/argus.sock",
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            bundledToolsDirectory: nil,
            inheritedPath: "/usr/bin:/bin"
        )

        #expect(environment["ARGUS_SOCKET_PATH"] == "/Users/tester/.argus/argus.sock")
        #expect(environment["ARGUS_WORKSPACE_ID"] == workspaceId.uuidString)
        #expect(environment["ARGUS_SURFACE_ID"] == surfaceId.uuidString)
        // A build that bundled no Companion CLI must leave PATH alone.
        #expect(environment["PATH"] == nil)
    }

    @Test
    func theBundledCompanionCLILeadsThePathWithoutDroppingInheritedEntries() {
        let environment = TerminalEnvironment.variables(
            socketPath: "/socket",
            workspaceId: UUID(),
            surfaceId: UUID(),
            bundledToolsDirectory: "/Applications/Argus.app/Contents/Resources/bin",
            inheritedPath: "/usr/bin:/bin"
        )

        #expect(environment["PATH"] == "/Applications/Argus.app/Contents/Resources/bin:/usr/bin:/bin")
    }

    /// Ghostty applies these variables after appending the application binary
    /// directory to PATH, so this value has to carry that directory itself.
    @Test
    func theApplicationBinaryDirectoryGhosttyAppendsIsPreserved() {
        let environment = TerminalEnvironment.variables(
            socketPath: "/socket",
            workspaceId: UUID(),
            surfaceId: UUID(),
            bundledToolsDirectory: "/Applications/Argus.app/Contents/Resources/bin",
            inheritedPath: "/usr/bin:/bin",
            applicationBinaryDirectory: "/Applications/Argus.app/Contents/MacOS"
        )

        #expect(
            environment["PATH"]
                == "/Applications/Argus.app/Contents/Resources/bin:/usr/bin:/bin:"
                + "/Applications/Argus.app/Contents/MacOS"
        )
        #expect(
            TerminalEnvironment.applicationBinaryDirectory(
                executableURL: URL(fileURLWithPath: "/Applications/Argus.app/Contents/MacOS/Argus")
            ) == "/Applications/Argus.app/Contents/MacOS"
        )
    }

    @Test
    func alreadyPresentDirectoriesAreNotDuplicated() {
        let tools = "/Applications/Argus.app/Contents/Resources/bin"
        let binary = "/Applications/Argus.app/Contents/MacOS"
        let environment = TerminalEnvironment.variables(
            socketPath: "/socket",
            workspaceId: UUID(),
            surfaceId: UUID(),
            bundledToolsDirectory: tools,
            inheritedPath: "/usr/bin:\(tools):\(binary):/bin",
            applicationBinaryDirectory: binary
        )

        #expect(environment["PATH"] == "\(tools):/usr/bin:\(binary):/bin")
    }

    @Test
    func inheritedCurrentDirectoryEntriesSurviveUnchanged() {
        let environment = TerminalEnvironment.variables(
            socketPath: "/socket",
            workspaceId: UUID(),
            surfaceId: UUID(),
            bundledToolsDirectory: "/tools",
            inheritedPath: "/usr/bin::/bin:",
            applicationBinaryDirectory: "/binary"
        )

        #expect(environment["PATH"] == "/tools:/usr/bin::/bin::/binary")
    }

    @Test
    func anEmptyInheritedPathBecomesTheToolsDirectoryAlone() {
        let environment = TerminalEnvironment.variables(
            socketPath: "/socket",
            workspaceId: UUID(),
            surfaceId: UUID(),
            bundledToolsDirectory: "/tools",
            inheritedPath: nil
        )

        #expect(environment["PATH"] == "/tools")
    }

    @Test
    func callerSuppliedValuesOverrideInjectedOnes() {
        let environment = TerminalEnvironment.variables(
            socketPath: "/socket",
            workspaceId: UUID(),
            surfaceId: UUID(),
            bundledToolsDirectory: "/tools",
            inheritedPath: "/usr/bin",
            applicationBinaryDirectory: "/binary",
            additional: ["PATH": "/only/this", "ARGUS_SOCKET_PATH": "/other/socket"]
        )

        #expect(environment["PATH"] == "/only/this")
        #expect(environment["ARGUS_SOCKET_PATH"] == "/other/socket")
    }

    @Test
    func theToolsDirectoryResolvesOnlyWhenItHoldsTheCompanionCLI() throws {
        let temporary = try TestTemporaryDirectory(prefix: "argus-terminal-environment")
        defer { temporary.remove() }
        let resources = temporary.url.resolvingSymlinksInPath()
        let tools = resources.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)

        #expect(TerminalEnvironment.bundledToolsDirectory(resourceURL: resources) == nil)

        let executable = tools.appendingPathComponent("argus")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        #expect(TerminalEnvironment.bundledToolsDirectory(resourceURL: resources) == tools.path)
        #expect(TerminalEnvironment.bundledToolsDirectory(resourceURL: nil) == nil)
    }
}
