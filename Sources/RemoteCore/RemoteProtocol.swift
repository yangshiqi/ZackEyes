import Foundation

public enum RemoteAgent: String, Codable, Sendable { case claude, codex }
public enum RemoteSessionState: String, Codable, Sendable { case unknown, working, waiting, idle, error }

public struct RemoteSessionSnapshot: Codable, Equatable, Sendable {
    public var id: String
    public var agent: RemoteAgent
    public var state: RemoteSessionState
    public var cwd: String?
    public var model: String?
    public var tool: String?
    public var approvalPolicy: String?
    public var sandboxType: String?
    public var permissionMode: String?
    public var reasoningEffort: String?
    public var lastActivity: Date
    public init(
        id: String, agent: RemoteAgent, state: RemoteSessionState, cwd: String? = nil,
        model: String? = nil, tool: String? = nil, lastActivity: Date,
        approvalPolicy: String? = nil, sandboxType: String? = nil, permissionMode: String? = nil,
        reasoningEffort: String? = nil
    ) {
        self.id = id
        self.agent = agent
        self.state = state
        self.cwd = cwd
        self.model = model
        self.tool = tool
        self.approvalPolicy = approvalPolicy
        self.sandboxType = sandboxType
        self.permissionMode = permissionMode
        self.reasoningEffort = reasoningEffort
        self.lastActivity = lastActivity
    }
    public var projectName: String {
        guard let cwd, !cwd.isEmpty else { return "Unknown" }
        let owner = cwd.range(of: "/.claude/worktrees/").map { String(cwd[..<$0.lowerBound]) } ?? cwd
        let name = (owner as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? "Unknown" : name
    }
}
public struct RemoteSnapshot: Codable, Equatable, Sendable {
    public var version: Int
    public var observedAt: Date
    public var sessions: [RemoteSessionSnapshot]
    public var truncated: Bool
    public init(version: Int = 1, observedAt: Date, sessions: [RemoteSessionSnapshot], truncated: Bool = false) {
        self.version = version
        self.observedAt = observedAt
        self.sessions = sessions
        self.truncated = truncated
    }
}
public enum RemoteProtocolError: Error, LocalizedError, Sendable {
    case invalidFrame, oversizedFrame, unsupportedVersion
    public var errorDescription: String? {
        switch self {
        case .invalidFrame: return "The remote returned invalid session data."
        case .oversizedFrame: return "The remote session frame exceeds the size limit."
        case .unsupportedVersion: return "The remote stream version is unsupported."
        }
    }
}
public enum RemoteFrameCodec {
    public static let maxFrameBytes = 1_048_576
    public static let maxSessions = 256
    public static func encode(_ snapshot: RemoteSnapshot) throws -> Data {
        try validate(snapshot)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        var data = try encoder.encode(snapshot)
        data.append(10)
        guard data.count <= maxFrameBytes else { throw RemoteProtocolError.oversizedFrame }
        return data
    }
    public static func decode(_ data: Data) throws -> RemoteSnapshot {
        guard data.count <= maxFrameBytes else { throw RemoteProtocolError.oversizedFrame }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let snapshot: RemoteSnapshot
        do { snapshot = try decoder.decode(RemoteSnapshot.self, from: data) } catch {
            throw RemoteProtocolError.invalidFrame
        }
        try validate(snapshot)
        return snapshot
    }
    public static func validate(_ snapshot: RemoteSnapshot) throws {
        guard snapshot.version == 1 else { throw RemoteProtocolError.unsupportedVersion }
        guard snapshot.sessions.count <= maxSessions, validDate(snapshot.observedAt) else {
            throw RemoteProtocolError.invalidFrame
        }
        var identities = Set<String>()
        for session in snapshot.sessions {
            guard !session.id.isEmpty, validString(session.id, bytes: 128), validString(session.cwd, bytes: 2048),
                validString(session.model, bytes: 128), validString(session.tool, bytes: 128),
                validString(session.approvalPolicy, bytes: 128), validString(session.sandboxType, bytes: 128),
                validString(session.permissionMode, bytes: 128), validString(session.reasoningEffort, bytes: 32),
                validDate(session.lastActivity),
                session.lastActivity <= snapshot.observedAt.addingTimeInterval(300),
                identities.insert("\(session.agent.rawValue):\(session.id)").inserted
            else { throw RemoteProtocolError.invalidFrame }
        }
    }
    private static func validDate(_ value: Date) -> Bool {
        value.timeIntervalSince1970.isFinite && (946_684_800...4_102_444_800).contains(value.timeIntervalSince1970)
    }
    private static func validString(_ value: String?, bytes: Int) -> Bool {
        guard let value else { return true }
        return value.utf8.count <= bytes
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}
/// Feed bounded pipe chunks. Incomplete lines never grow without a limit.
public struct RemoteLineFramer: Sendable {
    private var buffer = Data()
    public init() {}
    public mutating func push(_ data: Data) throws -> [RemoteSnapshot] {
        guard data.count <= RemoteFrameCodec.maxFrameBytes else { throw RemoteProtocolError.oversizedFrame }
        buffer.append(data)
        var snapshots: [RemoteSnapshot] = []
        while let newline = buffer.firstIndex(of: 10) {
            let count = buffer.distance(from: buffer.startIndex, to: newline)
            guard count + 1 <= RemoteFrameCodec.maxFrameBytes else { throw RemoteProtocolError.oversizedFrame }
            let frame = Data(buffer.prefix(count))
            buffer.removeFirst(count + 1)
            snapshots.append(try RemoteFrameCodec.decode(frame))
        }
        guard buffer.count < RemoteFrameCodec.maxFrameBytes else { throw RemoteProtocolError.oversizedFrame }
        return snapshots
    }
    public func finish() throws {
        if !buffer.isEmpty { throw RemoteProtocolError.invalidFrame }
    }
}
