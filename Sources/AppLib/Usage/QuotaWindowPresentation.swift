import Foundation
import Shared

enum UsageQuotaWindow: String, CaseIterable, Hashable, Sendable {
    case fiveHour
    case sevenDay

    var label: String {
        switch self {
        case .fiveHour: "5h"
        case .sevenDay: "7d"
        }
    }

    var duration: TimeInterval {
        switch self {
        case .fiveHour: TimeWindowProgress.fiveHours
        case .sevenDay: TimeWindowProgress.sevenDays
        }
    }
}

/// Pure description of the quota rows that are meaningful for one usage
/// reading. A missing axis in a fresh Codex reading means that window is not
/// currently offered; it must not turn into a hard-coded "5h —" row.
struct QuotaWindowPresentation: Equatable, Sendable {
    let windows: [UsageQuotaWindow]

    init(fiveHourUsedPct: Double?, sevenDayUsedPct: Double?) {
        var visible: [UsageQuotaWindow] = []
        if fiveHourUsedPct != nil { visible.append(.fiveHour) }
        if sevenDayUsedPct != nil { visible.append(.sevenDay) }
        windows = visible
    }

    private init(windows: [UsageQuotaWindow]) {
        self.windows = windows
    }

    var primary: UsageQuotaWindow? { windows.first }
    var secondary: UsageQuotaWindow? { windows.dropFirst().first }

    static func union(
        _ lhs: QuotaWindowPresentation,
        _ rhs: QuotaWindowPresentation
    ) -> QuotaWindowPresentation {
        QuotaWindowPresentation(
            windows: UsageQuotaWindow.allCases.filter {
                lhs.windows.contains($0) || rhs.windows.contains($0)
            }
        )
    }
}

extension UsageTracker.Snapshot {
    func quotaWindowPresentation(for agent: AgentKind) -> QuotaWindowPresentation {
        QuotaWindowPresentation(
            fiveHourUsedPct: fiveHourUsedPct(for: agent),
            sevenDayUsedPct: sevenDayUsedPct(for: agent)
        )
    }

    func usedPct(for window: UsageQuotaWindow, agent: AgentKind) -> Double? {
        switch window {
        case .fiveHour: fiveHourUsedPct(for: agent)
        case .sevenDay: sevenDayUsedPct(for: agent)
        }
    }

    func resetsAt(for window: UsageQuotaWindow, agent: AgentKind) -> Date? {
        switch (agent, window) {
        case (.claude, .fiveHour): fiveHourResetsAt
        case (.claude, .sevenDay): sevenDayResetsAt
        case (.codex, .fiveHour): codexFiveHourResetsAt
        case (.codex, .sevenDay): codexSevenDayResetsAt
        }
    }

    func eta(for window: UsageQuotaWindow, agent: AgentKind) -> CapETA? {
        guard window == .fiveHour else { return nil }
        return agent == .codex ? codexFiveHourETA : fiveHourETA
    }

    func hasAuthoritativeQuotaReading(for agent: AgentKind) -> Bool {
        switch agent {
        case .claude: lastUpdated != nil
        case .codex: codexLastUpdated != nil
        }
    }
}
