import Foundation
import CoreFoundation

/// Account credit balance reported by Codex. It is neither a dollar amount nor
/// proof that a particular model is available; explicit limits still apply.
public struct CodexCredits: Equatable, Sendable {
    public let hasCredits: Bool
    public let unlimited: Bool
    public let balance: Decimal?

    /// Unlimited credits or a confirmed positive balance can fund extra usage.
    public var isAvailable: Bool { unlimited || (hasCredits && (balance ?? 0) > 0) }

    /// Format raw credit units with two decimal places, never as a dollar amount.
    public var balanceLabel: String {
        if unlimited { return "Unlimited" }
        guard let balance else { return "—" }
        if balance > 0 && balance < Decimal(string: "0.01")! { return "<0.01" }
        let format = NumberFormatter()
        format.locale = Locale(identifier: "en_US")
        format.numberStyle = .decimal
        format.maximumFractionDigits = 2
        return format.string(from: NSDecimalNumber(decimal: balance)) ?? "—"
    }

    /// Abbreviate the same balance for narrow notch chips without losing its unit.
    public var compactBalanceLabel: String {
        if unlimited { return "∞" }
        guard let balance else { return "—" }
        if balance >= 1000 {
            let format = NumberFormatter()
            format.locale = Locale(identifier: "en_US")
            format.maximumFractionDigits = 2
            return (format.string(from: NSDecimalNumber(decimal: balance / 1000)) ?? "—") + "k"
        }
        return balanceLabel
    }

    /// Decode strict JSON flags and a bounded decimal; malformed amounts stay unknown.
    static func decode(_ fields: [String: Any]?) -> CodexCredits? {
        guard let fields else { return nil }
        let raw: String?
        switch fields["balance"] {
        case let value as String: raw = value
        case let value as NSNumber where CFGetTypeID(value) != CFBooleanGetTypeID(): raw = value.stringValue
        default: raw = nil
        }
        let balance = raw.flatMap { text -> Decimal? in
            guard text.range(of: #"^[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
                  text.count <= 64, let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
                  !value.isNaN else { return nil }
            return value
        }
        /// JSON numbers such as 0/1 are not evidence of a Boolean availability flag.
        func flag(_ key: String) -> Bool {
            guard let number = fields[key] as? NSNumber,
                  CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
            return number.boolValue
        }
        return CodexCredits(hasCredits: flag("has_credits"), unlimited: flag("unlimited"), balance: balance)
    }
}

public extension UsageTracker.Snapshot {
    /// Credit balances are live observations. Never revive an old balance from
    /// the quota cache, or refresh it merely because unrelated log text changed.
    func creditsInUse(at now: Date = Date()) -> CodexCredits? {
        let exhaustedWindow = ((codexFiveHourUsedPct ?? 0) >= 100
            && (codexFiveHourResetsAt.map { $0 > now } ?? true))
            || ((codexSevenDayUsedPct ?? 0) >= 100
                && (codexSevenDayResetsAt.map { $0 > now } ?? true))
        guard exhaustedWindow, codexCreditsInUse, !codexLimitReached,
              codexCreditsPlanResetAt.map({ $0 > now }) ?? true,
              let credits = codexCredits, credits.isAvailable,
              let updated = codexCreditsUpdatedAt,
              updated <= now.addingTimeInterval(300),
              now.timeIntervalSince(updated) < UsageFreshness.staleAfter else { return nil }
        return credits
    }
}

extension UsageTracker.CodexRateLimitObservation {
    /// Use this observation's binding deadline, independently of other sessions.
    var creditPlanResetAt: Date? {
        guard isUsingCredits else { return nil }
        return UsageTracker.bindingReset(fiveUsed: fiveHourUsedPct, fiveReset: fiveHourResetsAt,
                                         sevenUsed: sevenDayUsedPct, sevenReset: sevenDayResetsAt)
    }
}
