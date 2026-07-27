import Testing
import Foundation
@testable import Shared

/// #205 — the guarantees `Data.write(.atomic)` does not give us. The flush
/// itself is not observable from a test; everything around it is, and those are
/// the parts that used to be missing or duplicated per caller.
struct AtomicFileWriterTests {

    private func tmpDir() throws -> String {
        let dir = NSTemporaryDirectory() + "/afw-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func writesNewFileWithOwnerOnlyPermissions() throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/config.json"

        #expect(try AtomicFileWriter.write(Data("hello".utf8), to: path))

        #expect(String(decoding: try Data(contentsOf: URL(fileURLWithPath: path)), as: UTF8.self) == "hello")
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(mode == 0o600, "a fresh file must not be group/world readable")
    }

    @Test func preservesThePermissionsOfAnExistingFile() throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/settings.json"
        FileManager.default.createFile(atPath: path, contents: Data("{}".utf8),
                                       attributes: [.posixPermissions: 0o644])

        try AtomicFileWriter.write(Data("{\"a\":1}".utf8), to: path)

        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(mode == 0o644, "we must not silently tighten a file the user chose to share")
    }

    /// Identical content is not worth a rewrite — callers back up before writing,
    /// so a rewrite per launch means a backup per launch.
    @Test func identicalContentIsNotRewritten() throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/same.json"
        let payload = Data("{\"stable\":true}".utf8)

        #expect(try AtomicFileWriter.write(payload, to: path) == true)
        let firstMtime = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date

        #expect(try AtomicFileWriter.write(payload, to: path) == false, "rewrote identical content")

        let secondMtime = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
        #expect(firstMtime == secondMtime)
    }

    /// The dotfiles case: ~/.claude symlinked into a git repo. Renaming onto the
    /// link would replace the link with a regular file.
    @Test func followsSymlinkToItsTarget() throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let real = dir + "/real.json"
        let link = dir + "/link.json"
        FileManager.default.createFile(atPath: real, contents: Data("{}".utf8))
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)

        try AtomicFileWriter.write(Data("{\"v\":2}".utf8), to: link)

        let type = try FileManager.default.attributesOfItem(atPath: link)[.type] as? FileAttributeType
        #expect(type == .typeSymbolicLink, "the symlink was replaced by a regular file")
        #expect(String(decoding: try Data(contentsOf: URL(fileURLWithPath: real)), as: UTF8.self) == "{\"v\":2}")
    }

    /// A dotfiles symlink whose target is missing: Foundation gives up
    /// resolving it, so we would rename over the LINK — destroying the very
    /// setup the symlink handling exists to protect (found in review).
    @Test func createsTheTargetOfADanglingSymlinkRatherThanReplacingTheLink() throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let missing = dir + "/not-there-yet.json"
        let link = dir + "/link.json"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: missing)

        try AtomicFileWriter.write(Data("{\"v\":1}".utf8), to: link)

        let type = try FileManager.default.attributesOfItem(atPath: link)[.type] as? FileAttributeType
        #expect(type == .typeSymbolicLink, "a dangling symlink was replaced by a regular file")
        #expect(FileManager.default.fileExists(atPath: missing), "the link's target was not created")
    }

    @Test func followsARelativeSymlink() throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        FileManager.default.createFile(atPath: dir + "/real.json", contents: Data("{}".utf8))
        try FileManager.default.createSymbolicLink(atPath: dir + "/rel.json", withDestinationPath: "real.json")

        try AtomicFileWriter.write(Data("{\"v\":3}".utf8), to: dir + "/rel.json")

        let type = try FileManager.default.attributesOfItem(atPath: dir + "/rel.json")[.type] as? FileAttributeType
        #expect(type == .typeSymbolicLink)
        #expect(String(decoding: try Data(contentsOf: URL(fileURLWithPath: dir + "/real.json")), as: UTF8.self) == "{\"v\":3}")
    }

    /// A self-referential link must make us refuse, not fall through to a
    /// rename that would replace the link with a regular file.
    @Test func refusesASymlinkLoopInsteadOfReplacingTheLink() throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let a = dir + "/a.json"
        try FileManager.default.createSymbolicLink(atPath: a, withDestinationPath: a)

        #expect(throws: AtomicFileWriter.WriteError.self) {
            try AtomicFileWriter.write(Data("{}".utf8), to: a)
        }
        let type = try FileManager.default.attributesOfItem(atPath: a)[.type] as? FileAttributeType
        #expect(type == .typeSymbolicLink, "the loop was resolved by clobbering the link")
    }

    @Test func leavesNoTemporaryFilesBehind() throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/clean.json"
        try AtomicFileWriter.write(Data("{}".utf8), to: path)

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty, "left temp files: \(leftovers)")
    }
}
