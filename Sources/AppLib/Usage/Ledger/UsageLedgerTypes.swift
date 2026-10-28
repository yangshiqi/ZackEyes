import CryptoKit
import Foundation
import Shared

/// The complete persistence allowlist. Source text and paths cannot be encoded.
struct UsageLedgerRecord: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case tokens, counter, tool, work, wait }
    var version = 1
    var id: String
    var session: String
    var agent: AgentKind
    var project: String
    var model: String
    var date: Date
    var kind: Kind
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    var tool: String? = nil
    var baseline: Bool? = nil
    var end: Date? = nil

    var tokens: Int { input + output + cacheWrite }
    var isValid: Bool {
        version == 1 && !id.isEmpty && id.utf8.count <= 128 && !session.isEmpty && session.utf8.count <= 128
            && [project, model, tool ?? ""].allSatisfy {
                $0.utf8.count <= 512 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            }
            && [input, output, cacheRead, cacheWrite].allSatisfy { (0...(kind == .counter ? CodexUsageTotals.maximumCumulativeTokens : 1_000_000_000)).contains($0) }
            && (baseline != true || kind == .counter)
            && date.timeIntervalSince1970.isFinite
            && (end.map { $0.timeIntervalSince1970.isFinite && $0 >= date } ?? true)
            && ((kind == .work || kind == .wait) == (end != nil))
    }

    /// Repeated scans/copies are observations, not a new authoritative revision.
    /// Source timestamps win; tied streaming snapshots retain the complete count.
    func supersedes(_ old: Self) -> Bool {
        if date != old.date { return date > old.date }
        let amount = input + output + cacheRead + cacheWrite
        let oldAmount = old.input + old.output + old.cacheRead + old.cacheWrite
        if amount != oldAmount { return amount > oldAmount }
        if baseline != old.baseline {
            // Explicitly observed usage wins; a newly discovered unknown
            // inherited baseline may correct an older unclassified counter.
            if baseline == false { return true }
            if old.baseline == false { return false }
            return baseline == true
        }
        if end != old.end { return (end ?? date) > (old.end ?? old.date) }
        return [project, model, tool ?? ""].joined(separator: "|")
            > [old.project, old.model, old.tool ?? ""].joined(separator: "|")
    }

    static func identity(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func label(_ raw: String?) -> String {
        guard let raw else { return "Unknown" }
        let clean = String(
            String.UnicodeScalarView(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "Unknown" : String(clean.prefix(96))
    }
}
