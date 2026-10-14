import CryptoKit
import Darwin
import Foundation
import Shared

/// One bounded block at a time; checkpoints contain parser metadata, never raw lines.
actor UsageArchiveImporter {
    struct Result: Sendable {
        var bytesRead = 0
        var parsedBytes = 0
        var rejected = 0
    }
    private struct Cursor: Codable {
        var device: Int32
        var inode: UInt64
        var modified: Double
        var size: UInt64
        var offset: UInt64 = 0
        var prefixLength: Int
        var prefix: String
        var boundary = ""
        var skipping = false
        var finished = false
        var rejected = 0
        var fullCoverage: Bool
        var state: UsageLedgerParser.State?
        var baseline: UsageLedgerRecord?
    }
    /// Keeps partial lines in memory only, up to one MiB. Offset always describes committed complete rows.
    private final class Reader {
        let handle: FileHandle
        let size: UInt64
        var position: UInt64
        var offset: UInt64
        var skipping: Bool
        var pending = Data()
        var rejected = 0
        init(handle: FileHandle, size: UInt64, offset: UInt64, skipping: Bool = false) throws {
            self.handle = handle
            self.size = size
            self.position = offset
            self.offset = offset
            self.skipping = skipping
            try handle.seek(toOffset: offset)
        }
        func next() throws -> [Data]? {
            guard position < size else { return nil }
            let data = try handle.read(upToCount: Int(min(262_144, size - position))) ?? Data()
            guard !data.isEmpty else { throw CocoaError(.fileReadUnknown) }
            var lines: [Data] = []
            for byte in data {
                position += 1
                if byte == 10 {
                    if !skipping && !pending.isEmpty { lines.append(pending) }
                    pending.removeAll(keepingCapacity: true)
                    skipping = false
                    offset = position
                } else if skipping {
                    offset = position
                } else {
                    pending.append(byte)
                    if pending.count > 1_048_576 {
                        pending.removeAll(keepingCapacity: false)
                        skipping = true
                        offset = position
                        rejected += 1
                    }
                }
            }
            return lines
        }
    }
    private let database: UsageArchiveDatabase
    private let throttle: Bool
    init(database: UsageArchiveDatabase, throttle: Bool = true) {
        self.database = database
        self.throttle = throttle
    }

    func importFile(
        _ url: URL, agent: AgentKind, cutoff: Date?, legacy: Bool = false,
        onProgress: @Sendable (Int) async -> Void = { _ in }
    ) async throws -> Result {
        let source = UsageLedgerRecord.identity((legacy ? "legacy:" : "") + url.standardizedFileURL.path)
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0,
            !legacy || (info.st_uid == getuid() && info.st_mode & 0o077 == 0)
        else { throw UsageArchiveDatabase.Failure.unsafeFile }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let size = UInt64(info.st_size)
        let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
        var result = Result()
        var cursor = try await database.checkpoint(source: source).map {
            try JSONDecoder().decode(Cursor.self, from: $0)
        }
        let compatible =
            cursor.map {
                $0.device == info.st_dev && $0.inode == info.st_ino && $0.size <= size
                    && (cutoff != nil || $0.fullCoverage)
            } ?? false
        if compatible, let saved = cursor, saved.size == size, saved.modified == modified, saved.finished {
            result.rejected = saved.rejected
            return result
        }
        func digest(at offset: UInt64, count: Int) throws -> String {
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: count) ?? Data()
            result.bytesRead += data.count
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        if compatible, let saved = cursor {
            let prefix = try digest(at: 0, count: saved.prefixLength)
            let boundary = try digest(at: saved.offset - min(saved.offset, 128), count: Int(min(saved.offset, 128)))
            if saved.prefix != prefix || saved.boundary != boundary
                || (saved.size == size && saved.modified != modified)
            {
                cursor = nil
            }
        } else {
            cursor = nil
        }
        if cursor == nil {
            let length = Int(min(size, 4096))
            cursor = Cursor(
                device: info.st_dev, inode: info.st_ino, modified: modified, size: size,
                prefixLength: length, prefix: try digest(at: 0, count: length), fullCoverage: cutoff == nil)
            if !legacy {
                let seedReader = try Reader(handle: handle, size: size, offset: 0)
                var objects: [[String: Any]] = []
                while objects.count < 32, let lines = try seedReader.next() {
                    objects += lines.prefix(32 - objects.count).compactMap {
                        (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
                    }
                    // Seed discovery is bounded even for malformed prefixes.
                    if seedReader.position >= 2_097_152 { break }
                }
                result.bytesRead += Int(seedReader.position)
                cursor!.state = UsageLedgerParser.seed(objects: objects, agent: agent, sourceID: source)
            }
        }
        guard var saved = cursor else { throw UsageArchiveDatabase.Failure.invalidRecord }
        saved.size = size
        saved.modified = modified
        saved.finished = false
        var oversizedCount = 0
        let reader = try Reader(handle: handle, size: size, offset: saved.offset, skipping: saved.skipping)
        while let lines = try reader.next() {
            let started = Date()
            try Task.checkCancellation()
            var issues = 0
            let records: [UsageLedgerRecord] = try autoreleasepool {
                if legacy {
                    return try lines.compactMap { line in
                        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                            issues += 1
                            return nil
                        }
                        if let version = object["version"] as? Int, version != 1 {
                            throw UsageLedgerStore.Failure.unsupportedVersion
                        }
                        guard let record = try? JSONDecoder().decode(UsageLedgerRecord.self, from: line), record.isValid
                        else {
                            issues += 1
                            return nil
                        }
                        return record
                    }
                }
                let objects: [[String: Any]] = lines.compactMap { line in
                    guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                        issues += 1
                        return nil
                    }
                    return object
                }
                guard var state = saved.state else { throw UsageArchiveDatabase.Failure.invalidRecord }
                let observations = UsageLedgerParser.consume(objects: objects, state: &state, onIssue: { issues += 1 })
                saved.state = state
                return observations
            }
            var kept: [UsageLedgerRecord] = []
            for record in records {
                if let cutoff, record.date < cutoff && (record.end ?? record.date) < cutoff {
                    if record.kind == .counter,
                        saved.baseline.map({
                            record.date > $0.date
                                || (record.date == $0.date && record.input + record.output > $0.input + $0.output)
                        }) ?? true
                    {
                        saved.baseline = record
                    }
                } else {
                    kept.append(record)
                }
            }
            saved.offset = reader.offset
            saved.skipping = reader.skipping
            saved.boundary = try digest(at: saved.offset - min(saved.offset, 128), count: Int(min(saved.offset, 128)))
            // Hashing uses the same handle; restore the streaming position.
            try handle.seek(toOffset: reader.position)
            try Task.checkCancellation()
            saved.rejected += issues + reader.rejected - oversizedCount
            oversizedCount = reader.rejected
            try await database.apply(records: kept, source: source, checkpoint: JSONEncoder().encode(saved))
            result.parsedBytes += lines.reduce(0) { $0 + $1.count + 1 }
            result.rejected = saved.rejected
            await onProgress(Int(reader.position))
            if throttle { try await Task.sleep(for: .seconds(max(0.01, min(1, Date().timeIntervalSince(started))))) }
        }
        result.bytesRead += Int(reader.position - (cursor?.offset ?? 0))
        result.rejected = saved.rejected
        saved.finished = true
        // The final old cumulative observation establishes the first new day's delta.
        try await database.apply(
            records: saved.baseline.map { [$0] } ?? [], source: source, checkpoint: JSONEncoder().encode(saved))
        return result
    }
}
