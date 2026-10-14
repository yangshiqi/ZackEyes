import Darwin
import Foundation

/// One owner serializes durable append and publishes only completed writes.
actor UsageLedgerStore {
    enum Failure: Error, LocalizedError {
        case unsafeFile, unsupportedVersion, invalidRecord, io
        var errorDescription: String? {
            switch self {
            case .unsafeFile: return "Usage history must be an owner-only regular file."
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

    init(url: URL) { self.url = url }

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
        let values = try parent.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true, values.isDirectory == true else { throw Failure.unsafeFile }
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw Failure.io }
        defer { close(fd) }
        try validate(fd)
        guard fchmod(fd, 0o600) == 0 else { throw Failure.io }
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
        while fsync(fd) != 0 { if errno != EINTR { throw Failure.io } }
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
        if rejected > 0 {
            warnings = ["Skipped \(rejected) invalid history records; some statistics may be incomplete."]
        }
        records = decoded
        needsNewline = data.last.map { $0 != 10 } ?? false
        loaded = true
    }

    private func validate(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
            info.st_size <= 512 * 1024 * 1024
        else { throw Failure.unsafeFile }
    }
}
