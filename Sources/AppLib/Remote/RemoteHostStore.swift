import Foundation
import Shared

public struct RemoteHost: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var destination: String
    public var enabled: Bool
    public init(id: UUID = UUID(), name: String, destination: String, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.destination = destination
        self.enabled = enabled
    }
}

public struct RemoteHostStore: Sendable {
    private struct Document: Codable {
        var version: Int
        var hosts: [RemoteHost]
    }
    public let url: URL
    public init(url: URL = URL(fileURLWithPath: NSHomeDirectory() + "/.zackeyes/remote-hosts.json")) {
        self.url = url
    }
    public static func validate(_ hosts: [RemoteHost]) throws {
        guard hosts.count <= 8, Set(hosts.map(\.id)).count == hosts.count else {
            throw RemoteHostError.invalidConfiguration
        }
        for host in hosts {
            guard !host.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                host.name.utf8.count <= 80,
                !host.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                host.destination.range(of: #"\A[A-Za-z0-9][A-Za-z0-9._@:-]{0,253}\z"#, options: .regularExpression)
                    != nil
            else { throw RemoteHostError.invalidConfiguration }
        }
    }
    public func load() throws -> [RemoteHost] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw RemoteHostError.invalidConfiguration }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= 64 * 1024 else { throw RemoteHostError.invalidConfiguration }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.read(upToCount: 64 * 1024 + 1) ?? Data()
        guard data.count <= 64 * 1024 else { throw RemoteHostError.invalidConfiguration }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.version == 1 else { throw RemoteHostError.invalidConfiguration }
        try Self.validate(document.hosts)
        return document.hosts
    }
    public func save(_ hosts: [RemoteHost]) throws {
        try Self.validate(hosts)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFileWriter.write(encoder.encode(Document(version: 1, hosts: hosts)), to: url.path)
    }
}

public enum RemoteHostError: Error, LocalizedError {
    case invalidConfiguration
    case disconnected(String)
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "Use up to 8 named hosts with a valid SSH alias or user@hostname."
        case .disconnected(let message): return message
        }
    }
}
