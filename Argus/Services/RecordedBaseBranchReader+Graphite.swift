import Foundation

extension RecordedBaseBranchReader {
    func readGraphite(repositoryPath: String, records: inout Records) throws {
        let output: String
        do {
            let result = try git(
                ["for-each-ref", "--format=%(refname)%00%(objectname)", "refs/branch-metadata/"],
                at: repositoryPath)
            guard result.terminationStatus == 0, let value = String(data: result.stdout, encoding: .utf8) else {
                throw RecordedBaseBranchReadError.graphiteUnreadable
            }
            output = value
            if !result.stderr.isEmpty {
                records.diagnose(RecordedBaseBranchReadError.graphiteUnreadable, fallback: .graphiteUnreadable)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            records.diagnose(error, fallback: .graphiteUnreadable)
            return
        }
        var batch: [GraphiteReference] = []
        var inputBytes = 0
        for record in output.split(separator: "\n") {
            try Task.checkCancellation()
            let fields = record.components(separatedBy: "\0")
            guard fields.count == 2, fields[0].hasPrefix("refs/branch-metadata/"),
                [40, 64].contains(fields[1].count), fields[1].allSatisfy(\.isHexDigit)
            else {
                records.diagnose(RecordedBaseBranchReadError.graphiteUnreadable, fallback: .graphiteUnreadable)
                continue
            }
            let branch = String(fields[0].dropFirst("refs/branch-metadata/".count))
            do {
                try Self.validateBranchName(branch, failure: .graphiteInvalidBranch)
                let reference = GraphiteReference(branch: branch, objectID: fields[1])
                if inputBytes + reference.inputLine.utf8.count > ExternalProcess.maximumInputBytes {
                    try readGraphiteReferences(batch, repositoryPath: repositoryPath, records: &records)
                    batch.removeAll(keepingCapacity: true)
                    inputBytes = 0
                }
                batch.append(reference)
                inputBytes += reference.inputLine.utf8.count
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                records.diagnose(error, fallback: .graphiteUnreadable)
            }
        }
        try readGraphiteReferences(batch, repositoryPath: repositoryPath, records: &records)
    }

    private func readGraphiteReferences(
        _ references: [GraphiteReference], repositoryPath: String, records: inout Records
    ) throws {
        guard !references.isEmpty else { return }
        do {
            let result = try git(
                ["cat-file", "--batch-check"], at: repositoryPath,
                standardInput: Data(references.map(\.inputLine).joined().utf8))
            guard result.terminationStatus == 0, let output = String(data: result.stdout, encoding: .utf8),
                output.hasSuffix("\n")
            else { throw RecordedBaseBranchReadError.graphiteUnreadable }
            let lines = output.split(separator: "\n")
            guard lines.count == references.count else { throw RecordedBaseBranchReadError.graphiteUnreadable }
            var blobs: [GraphiteBlob] = []
            for (reference, line) in zip(references, lines) {
                try Task.checkCancellation()
                let fields = line.split(separator: " ")
                guard fields.count == 3, fields[0] == reference.objectID, fields[1] == "blob",
                    let size = Int(fields[2]), size >= 0
                else {
                    records.diagnose(RecordedBaseBranchReadError.graphiteUnreadable, fallback: .graphiteUnreadable)
                    continue
                }
                guard size <= Self.maximumMetadataBytes else {
                    records.diagnose(RecordedBaseBranchReadError.graphiteTooLarge, fallback: .graphiteTooLarge)
                    continue
                }
                blobs.append(GraphiteBlob(reference: reference, size: size))
            }
            try readGraphiteBlobs(blobs, repositoryPath: repositoryPath, records: &records)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try readGraphiteIndividually(references, repositoryPath: repositoryPath, records: &records)
        }
    }

    private func readGraphiteBlobs(
        _ blobs: [GraphiteBlob], repositoryPath: String, records: inout Records
    ) throws {
        var batch: [GraphiteBlob] = []
        var outputBytes = 0
        for blob in blobs {
            try Task.checkCancellation()
            if outputBytes + blob.framedByteCount > Self.maximumMetadataBytes {
                try readGraphiteBlobBatch(batch, repositoryPath: repositoryPath, records: &records)
                batch.removeAll(keepingCapacity: true)
                outputBytes = 0
            }
            if blob.framedByteCount > Self.maximumMetadataBytes {
                try readGraphiteIndividually([blob.reference], repositoryPath: repositoryPath, records: &records)
            } else {
                batch.append(blob)
                outputBytes += blob.framedByteCount
            }
        }
        try readGraphiteBlobBatch(batch, repositoryPath: repositoryPath, records: &records)
    }

    private func readGraphiteBlobBatch(
        _ blobs: [GraphiteBlob], repositoryPath: String, records: inout Records
    ) throws {
        guard !blobs.isEmpty else { return }
        do {
            let result = try git(
                ["cat-file", "--batch"], at: repositoryPath,
                standardInput: Data(blobs.map(\.reference.inputLine).joined().utf8))
            guard result.terminationStatus == 0,
                result.stdout.count == blobs.reduce(0, { $0 + $1.framedByteCount })
            else { throw RecordedBaseBranchReadError.graphiteUnreadable }
            var offset = 0
            for blob in blobs {
                try Task.checkCancellation()
                let header = Data(blob.header.utf8)
                let contentStart = offset + header.count
                let contentEnd = contentStart + blob.size
                guard result.stdout[offset..<contentStart].elementsEqual(header),
                    result.stdout[contentEnd] == UInt8(ascii: "\n")
                else { throw RecordedBaseBranchReadError.graphiteUnreadable }
                recordGraphiteParent(
                    result.stdout.subdata(in: contentStart..<contentEnd), branch: blob.reference.branch,
                    records: &records)
                offset = contentEnd + 1
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try readGraphiteIndividually(blobs.map(\.reference), repositoryPath: repositoryPath, records: &records)
        }
    }

    private func readGraphiteIndividually(
        _ references: [GraphiteReference], repositoryPath: String, records: inout Records
    ) throws {
        for reference in references {
            try Task.checkCancellation()
            do {
                let data = try graphiteData(objectID: reference.objectID, repositoryPath: repositoryPath)
                recordGraphiteParent(data, branch: reference.branch, records: &records)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                records.diagnose(error, fallback: .graphiteUnreadable)
            }
        }
    }

    private func graphiteData(objectID: String, repositoryPath: String) throws -> Data {
        let type = try gitOutput(
            ["cat-file", "-t", objectID], at: repositoryPath, failure: .graphiteUnreadable)
        guard type == "blob\n" else { throw RecordedBaseBranchReadError.graphiteUnreadable }
        let sizeOutput = try gitOutput(
            ["cat-file", "-s", objectID], at: repositoryPath, failure: .graphiteUnreadable)
        guard let size = Int(sizeOutput.trimmingCharacters(in: .whitespacesAndNewlines)), size >= 0 else {
            throw RecordedBaseBranchReadError.graphiteUnreadable
        }
        guard size <= Self.maximumMetadataBytes else { throw RecordedBaseBranchReadError.graphiteTooLarge }
        let result = try git(["cat-file", "blob", objectID], at: repositoryPath)
        guard result.terminationStatus == 0 else { throw RecordedBaseBranchReadError.graphiteUnreadable }
        return result.stdout
    }

    private func recordGraphiteParent(_ data: Data, branch: String, records: inout Records) {
        do {
            let value = try JSONDecoder().decode(GraphiteParentMetadata.self, from: data).parentBranchName
            if let value, let parent = try Self.parentName(value, branch: branch, failure: .graphiteInvalidBranch) {
                records.toolParents[branch, default: []].insert(parent)
            }
        } catch {
            records.diagnose(error, fallback: .graphiteMalformed)
        }
    }
}

private struct GraphiteReference {
    let branch: String
    let objectID: String

    var inputLine: String { "\(objectID)\n" }
}

private struct GraphiteBlob {
    let reference: GraphiteReference
    let size: Int

    var header: String { "\(reference.objectID) blob \(size)\n" }
    var framedByteCount: Int { header.utf8.count + size + 1 }
}

private struct GraphiteParentMetadata: Decodable {
    let parentBranchName: String?
}
