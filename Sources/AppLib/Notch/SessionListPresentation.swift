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
        if session.needsAttention { return .needsYou }
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

    static func duplicateDisplayNames(in sessions: [SessionInfo]) -> Set<String> {
        let counts = sessions.reduce(into: [String: Int]()) { result, session in
            result[session.displayName, default: 0] += 1
        }
        return Set(counts.compactMap { name, count in count > 1 ? name : nil })
    }

    static func title(for session: SessionInfo, duplicateDisplayNames: Set<String>) -> String {
        guard duplicateDisplayNames.contains(session.displayName) else {
            return session.displayName
        }
        return "\(session.displayName) · \(session.id.prefix(4))"
    }
}
