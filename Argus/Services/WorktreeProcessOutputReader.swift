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

    func drain() {
        guard !isFinished else { return }
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fileDescriptor, &buffer, buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
            } else if count == 0 {
                close()
                return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                close()
                return
            }
        }
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

    init(stdout: Pipe, stderr: Pipe) {
        stdoutReader = WorktreeProcessStreamReader(fileHandle: stdout.fileHandleForReading)
        stderrReader = WorktreeProcessStreamReader(fileHandle: stderr.fileHandleForReading)
    }

    var isFinished: Bool {
        stdoutReader.isFinished && stderrReader.isFinished
    }

    func drain() {
        stdoutReader.drain()
        stderrReader.drain()
    }

    func close() {
        stdoutReader.close()
        stderrReader.close()
    }

    var output: (stdout: Data, stderr: Data) {
        (stdoutReader.data, stderrReader.data)
    }
}
