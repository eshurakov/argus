import ArgumentParser
import ArgusIPC
import Foundation

/// Shared plumbing for command output: one socket client, one JSON encoding,
/// and one place where a failure becomes stderr text plus an exit code.
enum ArgusCommandOutput {
    static func client(timeout: TimeInterval) -> ArgusSocketClient {
        ArgusSocketClient(path: ArgusSocketClient.resolvedPath(), responseTimeout: timeout)
    }

    static func printJSON<Value: Encodable>(_ value: Value) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let text = String(data: try encoder.encode(value), encoding: .utf8) else {
            throw ArgusCLIError.malformedResponse("Could not encode the result as JSON")
        }
        print(text)
    }

    static func reportingFailures(_ body: () throws -> Void) throws {
        do {
            try body()
        } catch let error as ArgusCLIError {
            FileHandle.standardError.write(Data("argus: \(error.description)\n".utf8))
            throw error.exitCode
        }
    }
}
