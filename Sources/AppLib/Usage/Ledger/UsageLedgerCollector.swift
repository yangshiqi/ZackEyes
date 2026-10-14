import Darwin
import Foundation
import Shared

/// Reads only the two transcript roots; fixture/demo stores never enter here.
actor UsageLedgerCollector {
    struct Scan: Sendable {
        var records: [UsageLedgerRecord]
        var issues: [String]
        var parsedFiles: Int
    }
    private struct Cached: Sendable {
        var modified: Date
        var size: Int
        var fileID: UInt64
        var records: [UsageLedgerRecord]
        var hasInvalidObservations: Bool
    }
    private let claudeRoot: URL
    private let codexRoot: URL
    private var cache: [String: Cached] = [:]

    init(claudeRoot: URL, codexRoot: URL) {
        self.claudeRoot = claudeRoot
        self.codexRoot = codexRoot
    }

    func scan() throws -> Scan {
        var scan = Scan(records: [], issues: [], parsedFiles: 0)
        var updated: [String: Cached] = [:]
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey,
        ]
        for (root, agent) in [(claudeRoot, AgentKind.claude), (codexRoot, .codex)] {
            try Task.checkCancellation()
            guard fm.fileExists(atPath: root.path) else { continue }
            guard (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else {
                scan.issues.append("Skipped a linked \(agent.rawValue) transcript directory.")
                continue
            }
            var failedWalk = false
            guard
                let walker = fm.enumerator(
                    at: root, includingPropertiesForKeys: Array(keys),
                    errorHandler: { _, _ in
                        failedWalk = true
                        return true
                    })
            else {
                scan.issues.append("Could not list \(agent.rawValue) transcripts.")
                continue
            }
            for case let file as URL in walker where file.pathExtension == "jsonl" {
                try Task.checkCancellation()
                guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true,
                    values.isSymbolicLink != true, let size = values.fileSize,
                    let modified = values.contentModificationDate
                else { continue }
                guard UsageTracker.shouldScanTranscript(isSymbolicLink: false, fileSize: size) else {
                    scan.issues.append("Skipped an oversized \(agent.rawValue) transcript.")
                    continue
                }
                let identity = file.standardizedFileURL.path
                let attributes = try? fm.attributesOfItem(atPath: file.path)
                let fileID = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
                let entry: Cached
                if let hit = cache[identity], hit.modified == modified, hit.size == size, hit.fileID == fileID {
                    entry = hit
                } else {
                    guard let text = try? Self.readTranscript(file) else {
                        scan.issues.append("Could not read a \(agent.rawValue) transcript.")
                        continue
                    }
                    var rejected = false
                    let observations = UsageLedgerParser.parse(
                        text: text, agent: agent, sourceID: UsageLedgerRecord.identity(identity),
                        onIssue: { rejected = true })
                    entry = Cached(
                        modified: modified, size: size, fileID: fileID, records: observations,
                        hasInvalidObservations: rejected)
                    scan.parsedFiles += 1
                }
                updated[identity] = entry
                scan.records.append(contentsOf: entry.records)
                if entry.hasInvalidObservations {
                    scan.issues.append(
                        "Skipped invalid \(agent.rawValue) observations; some history may be incomplete.")
                }
            }
            if failedWalk { scan.issues.append("Some \(agent.rawValue) transcript directories could not be read.") }
        }
        try Task.checkCancellation()
        cache = updated
        scan.issues = Array(Set(scan.issues)).sorted()
        return scan
    }
    private static func readTranscript(_ url: URL) throws -> String {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            info.st_size <= UsageTracker.maxTranscriptBytes
        else { throw CocoaError(.fileReadTooLarge) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var data = Data()
        while let chunk = try handle.read(upToCount: min(65_536, UsageTracker.maxTranscriptBytes - data.count + 1)),
            !chunk.isEmpty
        {
            try Task.checkCancellation()
            data.append(chunk)
            guard data.count <= UsageTracker.maxTranscriptBytes else { throw CocoaError(.fileReadTooLarge) }
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return text
    }

}
