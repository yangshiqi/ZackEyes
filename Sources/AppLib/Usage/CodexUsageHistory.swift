import CoreFoundation
import Darwin
import Foundation

/// Resolves count-only predecessors of paginated rollouts. No source text,
/// filesystem path or raw thread identity is persisted by callers.
enum CodexUsageHistory {
    struct Reference: Hashable, Sendable {
        let fileID: String
        let offset: UInt64
    }
    struct Baseline: Sendable {
        let usage: CodexUsageTotals
        let date: Date
    }

    static func metadata(in text: String) -> [String: Any]? {
        for line in text.split(separator: "\n", maxSplits: 32).prefix(32) {
            guard line.utf8.count <= 1_048_576,
                  let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "session_meta" else { continue }
            return object["payload"] as? [String: Any]
        }
        return nil
    }
    static func hasInheritedHistory(_ metadata: [String: Any]?) -> Bool {
        guard let value = metadata?["history_base"] else { return false }
        return !(value is NSNull)
    }
    static func reference(_ metadata: [String: Any]?) -> Reference? {
        guard let base = metadata?["history_base"] as? [String: Any],
              let rawID = base["thread_id"] as? String, let id = UUID(uuidString: rawID),
              let number = base["end_byte_offset"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0,
              number.doubleValue <= Double(Int64.max / 2),
              number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
        return Reference(fileID: id.uuidString.lowercased(), offset: number.uint64Value)
    }

    static func fileIndex(root: URL) -> [String: URL] {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey]
        guard (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == false,
              let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [:] }
        var files: [String: URL] = [:]
        var ambiguous: Set<String> = []
        for case let url as URL in walker {
            guard !Task.isCancelled else { break }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isSymbolicLink == true { walker.skipDescendants(); continue }
            guard values.isRegularFile == true, url.pathExtension == "jsonl",
                  let id = UUID(uuidString: String(url.deletingPathExtension().lastPathComponent.suffix(36)))
            else { continue }
            let key = id.uuidString.lowercased()
            if files[key] != nil { ambiguous.insert(key) }
            files[key] = url
        }
        for key in ambiguous { files.removeValue(forKey: key) }
        return files
    }

    static func metadata(inFile url: URL) -> [String: Any]? {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        var data = Data()
        while data.count < 1_048_576 {
            guard let part = try? handle.read(upToCount: min(4096, 1_048_576 - data.count)), !part.isEmpty else { break }
            data.append(part)
            // Canonical SessionMeta is the first rollout row. Never expose or
            // retain its instructions; only its count-history reference is used.
            if data.contains(10) { break }
        }
        return metadata(in: String(decoding: data, as: UTF8.self))
    }

    static func resolve(_ reference: Reference, files: [String: URL]) -> Baseline? {
        var budget = 8 * 1_048_576
        var visited: Set<Reference> = []
        return resolve(reference, files: files, budget: &budget, visited: &visited)
    }
    private static func resolve(_ reference: Reference, files: [String: URL], budget: inout Int,
                                visited: inout Set<Reference>) -> Baseline? {
        guard !Task.isCancelled, visited.count < 32, visited.insert(reference).inserted,
              let url = files[reference.fileID] else { return nil }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, reference.offset <= UInt64(info.st_size) else { return nil }
        if reference.offset == 0 { return Baseline(usage: .init(input: 0, output: 0), date: .distantPast) }
        // Read backwards in bounded windows. The pinned offset is a complete
        // JSONL boundary, not the parent's mutable EOF.
        guard (try? handle.seek(toOffset: reference.offset - 1)) != nil,
              (try? handle.read(upToCount: 1)) == Data([10]) else { return nil }
        var window = min(Int(reference.offset), 1_048_576)
        while budget >= window, window > 0 {
            let start = reference.offset - UInt64(window)
            guard (try? handle.seek(toOffset: start)) != nil,
                  let data = try? handle.read(upToCount: window), data.count == window else { return nil }
            budget -= window
            let lines = data.split(separator: 10, omittingEmptySubsequences: false)
            for line in lines.dropFirst(start == 0 ? 0 : 1).reversed() {
                guard line.count <= 1_048_576, line.range(of: Data("\"token_count\"".utf8)) != nil,
                      let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      object["type"] as? String == "event_msg",
                      let payload = object["payload"] as? [String: Any], payload["type"] as? String == "token_count",
                      let totals = (payload["info"] as? [String: Any])?["total_token_usage"] as? [String: Any],
                      let input = CodexUsageTotals.decodeCounter(totals["input_tokens"]),
                      let output = CodexUsageTotals.decodeCounter(totals["output_tokens"]),
                      let cached = CodexUsageTotals.decodeCounter(totals["cached_input_tokens"] ?? 0),
                      let writes = CodexUsageTotals.decodeCounter(totals["cache_write_input_tokens"] ?? 0),
                      let timestamp = object["timestamp"] as? String,
                      let date = parseDate(timestamp) else { continue }
                return Baseline(usage: .init(input: input, cached: cached, writes: writes, output: output), date: date)
            }
            if start == 0 {
                let meta = metadata(in: String(decoding: data, as: UTF8.self))
                if let parent = self.reference(meta) {
                    return resolve(parent, files: files, budget: &budget, visited: &visited)
                }
                return hasInheritedHistory(meta) || meta == nil ? nil
                    : Baseline(usage: .init(input: 0, output: 0), date: .distantPast)
            }
            window = min(Int(reference.offset), window * 2)
        }
        return nil
    }
    private static func parseDate(_ raw: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}
