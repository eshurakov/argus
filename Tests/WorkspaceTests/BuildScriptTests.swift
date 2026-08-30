import Foundation
import Testing

@Suite
struct BuildScriptTests {
    @Test
    func buildFailsOnSigningErrorsAndVerifiesTheFinalBundle() throws {
        let script = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/build.sh"),
            encoding: .utf8
        )

        #expect(script.contains("codesign --force --deep --sign - \"${app_path}\""))
        #expect(script.contains("codesign --verify --deep --strict \"${app_path}\""))
        #expect(!script.contains("codesign --force --deep --sign - \"${app_path}\" 2>/dev/null || true"))
    }
    @Test
    func quitRunningTargetsTheProcessesReturnedByNameLookup() throws {
        let fixture = try QuitRunningFixture(forceKill: false)
        defer { fixture.remove() }

        try fixture.run()

        let scriptCalls = try fixture.read(fixture.scriptLog)
        #expect(scriptCalls.contains { $0.contains("runningApplicationWithProcessIdentifier(123)") })
        #expect(scriptCalls.contains { $0.contains("runningApplicationWithProcessIdentifier(456)") })
        #expect(scriptCalls.allSatisfy { !$0.contains("tell application") })
        let killCalls = try fixture.read(fixture.killLog)
        #expect(killCalls.filter { $0.hasPrefix("-9 ") }.isEmpty)
    }

    @Test
    func quitRunningForceKillsOnlyTheProcessesThatRemainAlive() throws {
        let fixture = try QuitRunningFixture(forceKill: true)
        defer { fixture.remove() }

        try fixture.run()

        let killCalls = try fixture.read(fixture.killLog)
        #expect(killCalls.filter { $0 == "-9 123" }.count == 1)
        #expect(killCalls.filter { $0 == "-9 456" }.count == 1)
        #expect(killCalls.filter { $0.hasPrefix("-0 ") }.count >= 5)
    }
}

private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private struct QuitRunningFixture {
    let root: URL
    let bin: URL
    let scriptLog: URL
    let killLog: URL
    let forceKill: Bool

    init(forceKill: Bool) throws {
        self.forceKill = forceKill
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("argus-quit-running-\(UUID().uuidString)", isDirectory: true)
        bin = root.appendingPathComponent("bin", isDirectory: true)
        scriptLog = root.appendingPathComponent("osascript.log")
        killLog = root.appendingPathComponent("kill.log")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)

        let pgrepScript = "#!/bin/bash\nprintf '123\\n456\\n'\n"
        try writeExecutable("pgrep", contents: pgrepScript)
        try writeExecutable(
            "osascript",
            contents: "#!/bin/bash\nprintf '%s\\n' \"$*\" >> \"$ARGUS_TEST_SCRIPT_LOG\"\n"
        )
        let killExit = forceKill ? "exit 0" : "exit 1"
        let killScript = """
            #!/bin/bash
            printf '%s\\n' "$*" >> "$ARGUS_TEST_KILL_LOG"
            if [ "$1" = "-0" ]; then
                \(killExit)
            fi
            """
        try writeExecutable("kill", contents: killScript)
        try writeExecutable("sleep", contents: "#!/bin/bash\nexit 0\n")
    }

    func run() throws {
        let script =
            repositoryRoot
            .appendingPathComponent("scripts/quit-running.sh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, "Argus"]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "ARGUS_PGREP_COMMAND": bin.appendingPathComponent("pgrep").path,
            "ARGUS_OSASCRIPT_COMMAND": bin.appendingPathComponent("osascript").path,
            "ARGUS_KILL_COMMAND": bin.appendingPathComponent("kill").path,
            "ARGUS_SLEEP_COMMAND": bin.appendingPathComponent("sleep").path,
            "ARGUS_TEST_SCRIPT_LOG": scriptLog.path,
            "ARGUS_TEST_KILL_LOG": killLog.path
        ]) { _, new in new }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        // The fake commands are complete; any non-zero script status is a fixture failure.
        #expect(process.terminationStatus == 0)
    }

    func read(_ url: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try String(contentsOf: url, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeExecutable(_ name: String, contents: String) throws {
        let url = bin.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
