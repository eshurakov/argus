import Darwin
import Foundation

private final class WorktreeProcessStreamReader {
    private var fileDescriptor: Int32
    private(set) var data = Data()
    private(set) var isFinished = false

    init(fileHandle: FileHandle) {
        fileDescriptor = Darwin.dup(fileHandle.fileDescriptor)
        try? fileHandle.close()
        guard fileDescriptor >= 0 else {
            isFinished = true
            return
        }

        let flags = Darwin.fcntl(fileDescriptor, F_GETFL)
        guard flags >= 0, Darwin.fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            close()
            return
        }
    }

    deinit {
        close()
    }

    func drain(maximumAdditionalBytes: Int?) -> Bool {
        guard !isFinished else { return false }
        var remaining = maximumAdditionalBytes
        let bufferSize = remaining.map { $0 < 16_384 ? $0 + 1 : 16_384 } ?? 16_384
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        for _ in 0..<16 {
            let readSize = remaining.map { $0 < buffer.count ? $0 + 1 : buffer.count } ?? buffer.count
            let count = Darwin.read(fileDescriptor, &buffer, readSize)
            if count > 0 {
                let accepted = min(count, remaining ?? count)
                data.append(buffer, count: accepted)
                remaining = remaining.map { $0 - accepted }
                if accepted < count { return true }
            } else if count == 0 {
                close()
                return false
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return false
            } else {
                close()
                return false
            }
        }
        return false
    }

    func close() {
        guard !isFinished else { return }
        isFinished = true
        if fileDescriptor >= 0 {
            Darwin.close(fileDescriptor)
            fileDescriptor = -1
        }
    }
}

final class WorktreeProcessOutputReader {
    private let stdoutReader: WorktreeProcessStreamReader
    private let stderrReader: WorktreeProcessStreamReader
    private let maximumOutputBytes: Int?

    init(stdout: Pipe, stderr: Pipe, maximumOutputBytes: Int? = nil) {
        self.maximumOutputBytes = maximumOutputBytes.map { max(0, $0) }
        stdoutReader = WorktreeProcessStreamReader(fileHandle: stdout.fileHandleForReading)
        stderrReader = WorktreeProcessStreamReader(fileHandle: stderr.fileHandleForReading)
    }

    var isFinished: Bool {
        stdoutReader.isFinished && stderrReader.isFinished
    }

    func drain() throws {
        if stdoutReader.drain(maximumAdditionalBytes: remainingOutputBytes)
            || stderrReader.drain(maximumAdditionalBytes: remainingOutputBytes)
        {
            close()
            throw ExternalProcessOutputLimitError()
        }
    }

    private var remainingOutputBytes: Int? {
        maximumOutputBytes.map { $0 - stdoutReader.data.count - stderrReader.data.count }
    }

    func close() {
        stdoutReader.close()
        stderrReader.close()
    }

    var output: (stdout: Data, stderr: Data) {
        (stdoutReader.data, stderrReader.data)
    }
}
