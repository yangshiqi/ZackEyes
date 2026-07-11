import Foundation
import Shared

enum SessionListGroup: Int, CaseIterable, Identifiable {
    case needsYou
    case running
    case recent

    var id: Self { self }

    var title: String {
        switch self {
        case .needsYou: return "Needs You"
        case .running: return "Running"
        case .recent: return "Recent"
        }
    }

    static func group(for session: SessionInfo) -> Self {
        if session.pendingPermission != nil || session.errorMessage != nil || session.state == .waiting {
            return .needsYou
        }
        return session.state == .working ? .running : .recent
    }
}

struct SessionListSection: Identifiable {
    let group: SessionListGroup
    let sessions: [SessionInfo]

    var id: SessionListGroup { group }
}

enum SessionListPresentation {
    static func sections(from orderedSessions: [SessionInfo]) -> [SessionListSection] {
        SessionListGroup.allCases.compactMap { group in
            let sessions = orderedSessions.filter { SessionListGroup.group(for: $0) == group }
            return sessions.isEmpty ? nil : SessionListSection(group: group, sessions: sessions)
        }
    }
}
