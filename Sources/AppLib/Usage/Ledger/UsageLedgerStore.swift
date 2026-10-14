import Darwin
import Foundation

/// One owner serializes durable append and publishes only completed writes.
actor UsageLedgerStore {
    enum Failure: Error, LocalizedError {
        case unsafeFile, unsupportedVersion, invalidRecord, io
        var errorDescription: String? {
            switch self {
            case .unsafeFile: return "Usage history requires a private directory (0700) and file (0600)."
            case .unsupportedVersion: return "Usage history uses an unsupported version; it was left unchanged."
            case .invalidRecord: return "An invalid usage observation was rejected."
            case .io: return "Usage history could not be read or saved."
            }
        }
    }
    let url: URL
    private var loaded = false
    private var records: [String: UsageLedgerRecord] = [:]
    private(set) var warnings: [String] = []
    private var needsNewline = false

    private let appendBytes: @Sendable (Int32, Data) throws -> Void

    init(url: URL, appendBytes: (@Sendable (Int32, Data) throws -> Void)? = nil) {
        self.url = url
        self.appendBytes = appendBytes ?? Self.writeAll
    }

    func summary(days: Int, now: Date, calendar: Calendar) throws -> UsageLedgerSummary {
        try load()
        return UsageLedgerSummary.make(records: Array(records.values), days: days, now: now, calendar: calendar)
    }

    func upsert(_ observations: [UsageLedgerRecord]) throws {
        try load()
        var changed: [String: UsageLedgerRecord] = [:]
        for observation in observations {
            guard observation.isValid else { throw Failure.invalidRecord }
            let old = changed[observation.id] ?? records[observation.id]
            if old.map({ observation.supersedes($0) }) ?? true { changed[observation.id] = observation }
        }
        guard !changed.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = Data()
        if needsNewline { data.append(10) }
        for record in changed.values.sorted(by: { $0.id < $1.id }) {
            data.append(try encoder.encode(record))
            data.append(10)
        }
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try validateParent()
        let values = try parent.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true, values.isDirectory == true else { throw Failure.unsafeFile }
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw Failure.io }
        defer { close(fd) }
        try validate(fd)
        guard fchmod(fd, 0o600) == 0 else { throw Failure.io }
        do {
            try appendBytes(fd, data)
            while fsync(fd) != 0 { if errno != EINTR { throw Failure.io } }
        } catch {
            // A short write may leave a partial row. Reload and separate its
            // tail before any retry, including retries in this same instance.
            loaded = false
            records.removeAll()
            needsNewline = false
            throw error
        }
        records.merge(changed) { _, new in new }
        needsNewline = false
    }

    private func load() throws {
        guard !loaded else { return }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT {
                loaded = true
                return
            }
            throw Failure.unsafeFile
        }
        defer { close(fd) }
        try validateParent()
        try validate(fd)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.read(upToCount: 512 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 512 * 1024 * 1024 else { throw Failure.unsafeFile }
        var decoded: [String: UsageLedgerRecord] = [:]
        var rejected = 0
        for line in data.split(separator: 10) {
            guard line.count <= 1_048_576,
                let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
            else {
                rejected += 1
                continue
            }
            if let version = object["version"] as? Int, version != 1 { throw Failure.unsupportedVersion }
            guard let record = try? JSONDecoder().decode(UsageLedgerRecord.self, from: Data(line)), record.isValid
            else {
                rejected += 1
                continue
            }
            if decoded[record.id].map({ record.supersedes($0) }) ?? true { decoded[record.id] = record }
        }
        warnings =
            rejected > 0 ? ["Skipped \(rejected) invalid history records; some statistics may be incomplete."] : []
        records = decoded
        needsNewline = data.last.map { $0 != 10 } ?? false
        loaded = true
    }

    private func validateParent() throws {
        let fd = open(url.deletingLastPathComponent().path, O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_NONBLOCK)
        guard fd >= 0 else { throw Failure.unsafeFile }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw Failure.unsafeFile
        }
    }

    private static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, address.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure.io }
                offset += count
            }
        }
    }

    private func validate(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
            info.st_mode & 0o077 == 0,
            info.st_size <= 512 * 1024 * 1024
        else { throw Failure.unsafeFile }
    }
}
