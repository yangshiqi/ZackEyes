import Foundation

/// A public announcement about an extra reset. This never represents the
/// current account's rate-limit state or its regular 5h/7d refresh time.
public struct CodexResetAnnouncement: Equatable, Sendable {
    public enum Kind: String, Sendable { case automatic, banked }
    public enum Phase: String, Sendable { case scheduled, announced, reportedComplete }

    public let kind: Kind
    public let phase: Phase
    public let sourceURL: URL
    public let announcedAt: Date
    public let expectedAt: Date?
    public let expectedDay: String?
    public let expectedWindowText: String?
    public let reportedDeliveredAt: Date?
    public let scope: String
    public let providerUpdatedAt: Date

    public var notificationKey: String { sourceURL.absoluteString + ":" + phase.rawValue }

    public func countdown(at now: Date) -> String? {
        guard let expectedAt, expectedAt > now else { return nil }
        let minutes = Int(ceil(expectedAt.timeIntervalSince(now) / 60))
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return "in \(minutes)m" }
        return remainder == 0 ? "in \(hours)h" : "in \(hours)h \(remainder)m"
    }

    public func notificationKey(at now: Date) -> String {
        if phase == .scheduled, let expectedAt,
           expectedAt.timeIntervalSince(now) > 0,
           expectedAt.timeIntervalSince(now) <= 2 * 3600 {
            return notificationKey + ":imminent"
        }
        return notificationKey
    }
}

/// Decodes only the documented v1 fields required for a notice. In
/// particular, `delivered_at` is evidence of a public report, not evidence
/// about this user's account.
public enum CodexResetFeed {
    private struct Payload: Decodable {
        let schema_version: Int
        let generated_at: Date
        let scheduled: Scheduled?
        let events: [Event]
    }

    private struct Scheduled: Decodable {
        let certainty: String
        let day: String?
        let scheduled_for: Date?
        let when_text: String?
        let url: URL
        let announced_at: Date
    }

    private struct Event: Decodable {
        let kind: String
        let scope: String?
        let url: URL
        let announced_at: Date?
        let delivered_at: Date?
        let seeded: Bool?
    }

    public static func latest(from data: Data, now: Date = Date()) -> CodexResetAnnouncement? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(Payload.self, from: data),
              payload.schema_version == 1,
              payload.generated_at <= now.addingTimeInterval(300),
              now.timeIntervalSince(payload.generated_at) <= 6 * 3600 else { return nil }

        if let scheduled = payload.scheduled,
           scheduled.certainty == "announced",
           let url = allowedSourceURL(scheduled.url),
           scheduled.announced_at <= now.addingTimeInterval(300),
           now.timeIntervalSince(scheduled.announced_at) < 7 * 86400,
           let day = validDay(scheduled.day),
           let dayStart = ISO8601DateFormatter().date(from: day + "T00:00:00Z"),
           dayStart > now.addingTimeInterval(-86400),
           dayStart < now.addingTimeInterval(8 * 86400),
           scheduled.scheduled_for.map({ $0 > now.addingTimeInterval(-2 * 3600) }) ?? true {
            return CodexResetAnnouncement(
                kind: .automatic, phase: .scheduled, sourceURL: url,
                announcedAt: scheduled.announced_at,
                expectedAt: scheduled.scheduled_for, expectedDay: day,
                expectedWindowText: scheduled.when_text.flatMap {
                    let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    return value.isEmpty ? nil : String(value.prefix(160))
                },
                reportedDeliveredAt: nil,
                scope: "See original announcement", providerUpdatedAt: payload.generated_at
            )
        }

        return payload.events.compactMap { event -> (CodexResetAnnouncement, Date)? in
            guard event.seeded != true,
                  let url = allowedSourceURL(event.url),
                  let announcedAt = event.announced_at,
                  announcedAt <= now.addingTimeInterval(300) else { return nil }
            let kind: CodexResetAnnouncement.Kind
            switch event.kind {
            case "regular": kind = .automatic
            case "banked": kind = .banked
            default: return nil
            }
            let phase: CodexResetAnnouncement.Phase = event.delivered_at == nil
                ? .announced : .reportedComplete
            let latestAt = event.delivered_at ?? announcedAt
            guard latestAt <= now.addingTimeInterval(300),
                  now.timeIntervalSince(latestAt) < 24 * 3600 else { return nil }
            let notice = CodexResetAnnouncement(
                kind: kind, phase: phase, sourceURL: url,
                announcedAt: announcedAt, expectedAt: nil, expectedDay: nil,
                expectedWindowText: nil,
                reportedDeliveredAt: event.delivered_at,
                scope: scopeLabel(event.scope), providerUpdatedAt: payload.generated_at
            )
            return (notice, latestAt)
        }.max(by: { $0.1 < $1.1 })?.0
    }

    private static func validDay(_ raw: String?) -> String? {
        guard let raw, raw.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              ISO8601DateFormatter().date(from: raw + "T00:00:00Z") != nil else { return nil }
        return raw
    }

    private static func allowedSourceURL(_ url: URL) -> URL? {
        guard url.scheme == "https", let host = url.host?.lowercased(),
              ["x.com", "twitter.com"].contains(host),
              url.pathComponents.contains("status") else { return nil }
        return url
    }

    private static func scopeLabel(_ raw: String?) -> String {
        switch raw?.lowercased() {
        case "all": return "All users (per announcement)"
        case "paid": return "Paid plans"
        case "plus+pro+business": return "Plus, Pro and Business"
        default: return "Check eligibility in original post"
        }
    }
}

public enum CodexResetAlertPolicy {
    public static func shouldNotify(
        _ notice: CodexResetAnnouncement,
        activeCodex: Bool,
        enabled: Bool,
        notificationsEnabled: Bool,
        lastKey: String?,
        now: Date = Date()
    ) -> Bool {
        guard activeCodex, enabled, notificationsEnabled,
              notice.notificationKey(at: now) != lastKey else { return false }
        let isFresh = now.timeIntervalSince(notice.announcedAt) >= 0
            && now.timeIntervalSince(notice.announcedAt) <= 6 * 3600
        let isImminent = notice.phase == .scheduled
            && notice.expectedAt.map { $0 > now && $0.timeIntervalSince(now) <= 2 * 3600 } == true
        return isFresh || isImminent
    }
}
