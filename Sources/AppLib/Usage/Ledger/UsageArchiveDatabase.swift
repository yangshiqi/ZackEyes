import Darwin
import Foundation
import SQLite3

/// Disk-backed observations and small day reports. No transcript bodies or raw paths enter this database.
actor UsageArchiveDatabase {
    enum Failure: Error, LocalizedError {
        case unsafeFile, unsupportedSchema, database, invalidRecord
        var errorDescription: String? {
            switch self {
            case .unsafeFile: return "Usage archives require an owned private directory and regular files (0700/0600)."
            case .unsupportedSchema: return "Usage archive version is unsupported; the database was left unchanged."
            case .database: return "Usage archives could not be read or saved."
            case .invalidRecord: return "An invalid Usage observation or checkpoint was rejected."
            }
        }
    }
    private final class Connection: @unchecked Sendable {
        let pointer: OpaquePointer
        init(_ pointer: OpaquePointer) { self.pointer = pointer }
        deinit { sqlite3_close_v2(pointer) }
    }
    private enum Value {
        case text(String)
        case number(Double)
        case blob(Data)
        case null
    }
    private let url: URL
    private var connection: Connection?
    private(set) var observationReads = 0
    init(url: URL) { self.url = url }

    static func zone(_ calendar: Calendar) -> String { "\(calendar.identifier):\(calendar.timeZone.identifier)" }

    private func openDatabase() throws {
        if connection != nil { return }
        let fm = FileManager.default
        let parent = url.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let dir = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard dir >= 0 else { throw Failure.unsafeFile }
        defer { close(dir) }
        var st = stat()
        guard fstat(dir, &st) == 0, st.st_uid == getuid(), st.st_mode & 0o077 == 0 else { throw Failure.unsafeFile }
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let path = url.path + suffix
            if lstat(path, &st) == 0 {
                guard st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid(), st.st_mode & 0o077 == 0,
                    st.st_nlink == 1
                else { throw Failure.unsafeFile }
            } else if errno != ENOENT {
                throw Failure.unsafeFile
            }
        }
        let fd = Darwin.open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw Failure.unsafeFile }
        close(fd)
        guard let canonical = realpath(url.path, nil) else { throw Failure.unsafeFile }
        defer { free(canonical) }
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(canonical, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK,
            let pointer
        else {
            if let pointer { sqlite3_close_v2(pointer) }
            throw Failure.database
        }
        connection = Connection(pointer)
        do {
            let version =
                try query("PRAGMA user_version").first?.first.flatMap { String(data: $0, encoding: .utf8) }.flatMap(
                    Int.init) ?? -1
            guard version == 0 || version == 1 else { throw Failure.unsupportedSchema }
            if version == 0 {
                guard try query("SELECT name FROM sqlite_master WHERE type='table'").isEmpty else {
                    throw Failure.unsupportedSchema
                }
                try execute("BEGIN IMMEDIATE")
                try execute(
                    "CREATE TABLE observations(id TEXT PRIMARY KEY, session TEXT NOT NULL, kind TEXT NOT NULL, date REAL NOT NULL, end REAL, body BLOB NOT NULL)"
                )
                try execute("CREATE INDEX observation_day ON observations(date)")
                try execute("CREATE INDEX observation_interval ON observations(end) WHERE end IS NOT NULL")
                try execute("CREATE INDEX observation_session ON observations(session,kind,date)")
                try execute("CREATE TABLE sources(id TEXT PRIMARY KEY, body BLOB NOT NULL)")
                try execute(
                    "CREATE TABLE archives(zone TEXT, start REAL, end REAL, dirty INTEGER NOT NULL DEFAULT 0, body BLOB NOT NULL, PRIMARY KEY(zone,start))"
                )
                try execute("CREATE TABLE metadata(key TEXT PRIMARY KEY, body BLOB NOT NULL)")
                try execute("PRAGMA user_version=1")
                try execute("COMMIT")
            }
            _ = try query("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA cache_size=-8192")
            sqlite3_busy_timeout(pointer, 3000)
        } catch {
            try? execute("ROLLBACK")
            connection = nil
            throw error
        }
    }
    private func statement(_ sql: String, _ values: [Value]) throws -> OpaquePointer {
        guard let connection else { throw Failure.database }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection.pointer, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Failure.database
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let string):
                result = string.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
            case .number(let number): result = sqlite3_bind_double(statement, index, number)
            case .blob(let data):
                result =
                    data.isEmpty
                    ? sqlite3_bind_zeroblob(statement, index, 0)
                    : data.withUnsafeBytes {
                        sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient)
                    }
            case .null: result = sqlite3_bind_null(statement, index)
            }
            if result != SQLITE_OK {
                sqlite3_finalize(statement)
                throw Failure.database
            }
        }
        return statement
    }
    private func execute(_ sql: String, _ values: [Value] = []) throws {
        let statement = try statement(sql, values)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.database }
    }
    private func query(_ sql: String, _ values: [Value] = []) throws -> [[Data]] {
        let statement = try statement(sql, values)
        defer { sqlite3_finalize(statement) }
        var rows: [[Data]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return rows }
            guard status == SQLITE_ROW else { throw Failure.database }
            rows.append(
                (0..<sqlite3_column_count(statement)).map { column in
                    guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
                    return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
                })
        }
    }
    func checkpoint(source: String) throws -> Data? {
        try openDatabase()
        return try query("SELECT body FROM sources WHERE id=?", [.text(source)]).first?.first
    }
    func metadata(_ key: String) throws -> Data? {
        try openDatabase()
        return try query("SELECT body FROM metadata WHERE key=?", [.text(key)]).first?.first
    }
    func setMetadata(_ key: String, _ data: Data) throws {
        try openDatabase()
        try execute("INSERT OR REPLACE INTO metadata VALUES(?,?)", [.text(key), .blob(data)])
    }
    func apply(records: [UsageLedgerRecord], source: String? = nil, checkpoint: Data? = nil) throws {
        try openDatabase()
        guard records.allSatisfy(\.isValid), (checkpoint?.count ?? 0) <= 2_097_152 else { throw Failure.invalidRecord }
        try Task.checkCancellation()
        try execute("BEGIN IMMEDIATE")
        do {
            for record in records {
                let old = try query("SELECT body FROM observations WHERE id=?", [.text(record.id)]).first?.first.map {
                    try JSONDecoder().decode(UsageLedgerRecord.self, from: $0)
                }
                if let old, !record.supersedes(old) { continue }
                for changed in [old, record].compactMap({ $0 }) {
                    try execute(
                        "UPDATE archives SET dirty=1 WHERE start<=? AND end>?",
                        [
                            .number((changed.end ?? changed.date).timeIntervalSince1970),
                            .number(changed.date.timeIntervalSince1970),
                        ])
                    if changed.kind == .counter {
                        let successor = try query(
                            "SELECT date FROM observations WHERE session=? AND kind='counter' AND date>? ORDER BY date LIMIT 1",
                            [.text(changed.session), .number(changed.date.timeIntervalSince1970)])
                        if let bytes = successor.first?.first, let text = String(data: bytes, encoding: .utf8),
                            let stamp = Double(text)
                        {
                            try execute(
                                "UPDATE archives SET dirty=1 WHERE start<=? AND end>?",
                                [.number(stamp), .number(stamp)])
                        }
                    }
                }
                try execute(
                    "INSERT OR REPLACE INTO observations VALUES(?,?,?,?,?,?)",
                    [
                        .text(record.id), .text(record.session), .text(record.kind.rawValue),
                        .number(record.date.timeIntervalSince1970),
                        record.end.map { .number($0.timeIntervalSince1970) } ?? .null,
                        .blob(try JSONEncoder().encode(record)),
                    ])
            }
            if let source, let checkpoint {
                try execute("INSERT OR REPLACE INTO sources VALUES(?,?)", [.text(source), .blob(checkpoint)])
            }
            try Task.checkCancellation()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
    func records(start: Date, end: Date) throws -> [UsageLedgerRecord] {
        try openDatabase()
        var rows = try query(
            "SELECT body FROM observations WHERE date>=? AND date<? UNION ALL SELECT body FROM observations WHERE end IS NOT NULL AND end>? AND date<?",
            [
                .number(start.timeIntervalSince1970), .number(end.timeIntervalSince1970),
                .number(start.timeIntervalSince1970), .number(start.timeIntervalSince1970),
            ])
        let sessions = try query(
            "SELECT DISTINCT session FROM observations WHERE kind='counter' AND date>=? AND date<?",
            [.number(start.timeIntervalSince1970), .number(end.timeIntervalSince1970)])
        for session in sessions {
            guard let bytes = session.first, let name = String(data: bytes, encoding: .utf8) else { continue }
            rows += try query(
                "SELECT body FROM observations WHERE session=? AND kind='counter' AND date=(SELECT MAX(date) FROM observations WHERE session=? AND kind='counter' AND date<?)",
                [.text(name), .text(name), .number(start.timeIntervalSince1970)])
        }
        observationReads += rows.count
        return try rows.map { row in
            try autoreleasepool { try JSONDecoder().decode(UsageLedgerRecord.self, from: row[0]) }
        }
    }
    func archive(day: Date, calendar: Calendar) throws {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return }
        let report = UsageLedgerSummary.make(
            records: try records(start: start, end: end), days: 1, now: end.addingTimeInterval(-1),
            calendar: calendar, rankLimit: Int.max, start: start, exclusiveEnd: end)
        try execute(
            "INSERT OR REPLACE INTO archives VALUES(?,?,?,0,?)",
            [
                .text(Self.zone(calendar)), .number(start.timeIntervalSince1970), .number(end.timeIntervalSince1970),
                .blob(try JSONEncoder().encode(report)),
            ])
    }
    func dirtyDays(calendar: Calendar) throws -> [Date] {
        try openDatabase()
        return try query("SELECT start FROM archives WHERE zone=? AND dirty=1", [.text(Self.zone(calendar))]).compactMap
        { row in
            String(data: row[0], encoding: .utf8).flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
        }
    }
    /// Only populated historical days need delayed corrections; empty bootstrap reports are not history coverage.
    func historicalCoverage() throws -> [DateInterval] {
        try openDatabase()
        let rows = try query(
            "SELECT DISTINCT start,end FROM archives WHERE json_extract(body,'$.hasHistory')=1 ORDER BY start")
        var intervals: [DateInterval] = []
        for row in rows {
            guard let start = String(data: row[0], encoding: .utf8).flatMap(Double.init),
                let end = String(data: row[1], encoding: .utf8).flatMap(Double.init)
            else { continue }
            let interval = DateInterval(
                start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end))
            if let last = intervals.last, last.end >= interval.start {
                intervals[intervals.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
            } else {
                intervals.append(interval)
            }
        }
        return intervals
    }
    func firstDate() throws -> Date? {
        try openDatabase()
        return try query("SELECT MIN(date) FROM observations").first?.first.flatMap {
            String(data: $0, encoding: .utf8)
        }.flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
    }
    func summary(days: Int, now: Date, calendar: Calendar) throws -> UsageLedgerSummary {
        try openDatabase()
        let end = calendar.startOfDay(for: now)
        let count = max(1, min(90, days))
        let start = calendar.date(byAdding: .day, value: -count, to: end)!
        let rows = try query(
            "SELECT body FROM archives WHERE zone=? AND start>=? AND start<? ORDER BY start",
            [.text(Self.zone(calendar)), .number(start.timeIntervalSince1970), .number(end.timeIntervalSince1970)])
        var result = UsageLedgerSummary.make(
            records: [], days: count, now: end.addingTimeInterval(-0.000001), calendar: calendar)
        var ranks = Array(repeating: [String: Int](), count: 3)
        let indices = Dictionary(uniqueKeysWithValues: result.days.enumerated().map { ($0.element.id, $0.offset) })
        let hours = Dictionary(uniqueKeysWithValues: result.heatmap.enumerated().map { ($0.element.id, $0.offset) })
        for row in rows {
            let report = try JSONDecoder().decode(UsageLedgerSummary.self, from: row[0])
            result.totalTokens += report.totalTokens
            result.activeSeconds += report.activeSeconds
            result.cacheInput += report.cacheInput
            result.cacheReused += report.cacheReused
            result.hasHistory = result.hasHistory || report.hasHistory
            for day in report.days { if let i = indices[day.id] { result.days[i] = day } }
            for hour in report.heatmap { if let i = hours[hour.id] { result.heatmap[i] = hour } }
            for (i, items) in [report.projects, report.models, report.tools].enumerated() {
                for item in items { ranks[i][item.name, default: 0] += item.value }
            }
        }
        let sorted: [[UsageLedgerSummary.Rank]] = ranks.map { counts in
            let items = counts.map { UsageLedgerSummary.Rank(name: $0.key, value: $0.value) }
            let ordered = items.sorted { left, right in
                left.value == right.value ? left.name < right.name : left.value > right.value
            }
            return Array(ordered.prefix(10))
        }
        result.projects = sorted[0]
        result.models = sorted[1]
        result.tools = sorted[2]
        if result.cacheInput > 0 { result.cacheHitRate = Double(result.cacheReused) / Double(result.cacheInput) }
        return result
    }
}
