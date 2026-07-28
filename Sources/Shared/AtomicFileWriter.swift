import Foundation

/// Durably replace a file, or leave it exactly as it was.
///
/// `Data.write(options: .atomic)` gets the rename right and stops there: the
/// bytes and the new directory entry are both still only in the page cache, so
/// a panic or power loss can roll the file back to its old contents — or leave
/// it empty. For `~/.claude/settings.json` that is the user's config, which
/// invariant #1 says we must never damage (#205).
///
/// Concurrency is out of scope. A fingerprint check before the write would
/// still leave a window between the check and the rename, so it would read as a
/// guarantee it cannot make. Two ZackEyes instances are prevented at startup
/// instead (#205) — but an edit made from outside the app, in an editor, can
/// still be lost by a read-modify-write here.
public enum AtomicFileWriter {

    public enum WriteError: Error, CustomStringConvertible {
        case failed(path: String, underlying: Error)
        case syncFailed(path: String, errno: Int32)
        /// The path could not be resolved to a real destination — a symlink
        /// loop, or a link we could not read. Refusing is the point: writing
        /// anyway would replace the link itself.
        case unresolvablePath(String)

        public var description: String {
            switch self {
            case .failed(let path, let underlying):
                return "could not write \(path): \(underlying)"
            case .syncFailed(let path, let code):
                return "could not flush \(path) to disk: \(String(validatingCString: strerror(code)) ?? "errno \(code)")"
            case .unresolvablePath(let path):
                return "could not resolve \(path) to a real file (symlink loop or unreadable link)"
            }
        }
    }

    /// Replace `path` with `data`.
    ///
    /// - Parameter permissions: mode for a file we create. An existing file keeps
    ///   its own mode bits (ACLs and extended attributes are NOT carried over —
    ///   `Data.write(.atomic)` never did either, and none of our files use them).
    ///   Defaults to `0o600`: several of these hold paths and third-party
    ///   commands, so they are owner-only from creation rather than after a
    ///   chmod.
    /// - Returns: `true` if bytes were written, `false` if they already matched —
    ///   no rewrite, no mtime bump, and no backup churn for callers that back up
    ///   before writing.
    /// - Throws: `WriteError`. Note the asymmetry: everything up to and including
    ///   the rename either succeeds or leaves the old file untouched, but a
    ///   `syncFailed` naming the *directory* is thrown after the rename has
    ///   already committed. The new contents are visible and only their
    ///   durability across a power loss is in doubt, so treat that case as
    ///   "written, maybe not flushed" — do not undo or re-run anything
    ///   destructive on the strength of it.
    @discardableResult
    public static func write(
        _ data: Data,
        to path: String,
        permissions: Int = 0o600
    ) throws -> Bool {
        // Some users link ~/.claude into a dotfiles repo. Renaming onto the link
        // would replace it with a regular file (#129/F-021).
        let target = try resolvingSymlink(path)

        if let current = FileManager.default.contents(atPath: target), current == data {
            return false
        }

        let directory = (target as NSString).deletingLastPathComponent
        let temp = (directory as NSString).appendingPathComponent(".\(UUID().uuidString).tmp")
        let mode = (try? FileManager.default.attributesOfItem(atPath: target)[.posixPermissions] as? Int)
            .flatMap { $0 } ?? permissions

        do {
            guard FileManager.default.createFile(
                    atPath: temp, contents: nil, attributes: [.posixPermissions: mode]),
                  let handle = FileHandle(forWritingAtPath: temp) else {
                throw WriteError.failed(path: target, underlying: CocoaError(.fileWriteUnknown))
            }
            try handle.write(contentsOf: data)

            // fsync on macOS only hands the blocks to the drive; the drive may
            // still hold them in a volatile cache. F_FULLFSYNC is the documented
            // way to ask for the real flush, and this is the one write where
            // that distinction is the whole point.
            try fullSync(handle.fileDescriptor, describing: target)
            try handle.close()

            guard rename(temp, target) == 0 else {
                throw WriteError.failed(
                    path: target,
                    underlying: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
            }
            try syncDirectory(directory)
            return true
        } catch {
            try? FileManager.default.removeItem(atPath: temp)
            throw (error as? WriteError) ?? .failed(path: target, underlying: error)
        }
    }

    /// Persist the rename itself, so a crash cannot leave the directory entry
    /// pointing at the old inode. Failing here means the new contents may not
    /// survive a power loss, which the caller asked us to guarantee — so it is
    /// an error, not a shrug.
    private static func syncDirectory(_ directory: String) throws {
        let fd = open(directory, O_RDONLY)
        guard fd >= 0 else {
            throw WriteError.syncFailed(path: directory, errno: errno)
        }
        defer { close(fd) }
        try fullSync(fd, describing: directory)
    }

    /// Ask the drive to actually flush, not just the kernel to hand the blocks
    /// over. Falls back to `fsync` ONLY where the filesystem does not implement
    /// the request — an I/O error must surface, not be downgraded into a weaker
    /// flush that then "succeeds".
    private static func fullSync(_ fd: Int32, describing path: String) throws {
        while true {
            if fcntl(fd, F_FULLFSYNC) != -1 { return }
            switch errno {
            case EINTR:
                continue
            case ENOTSUP, ENOTTY, EINVAL:
                // Network mounts and some virtualised filesystems. Weaker, but
                // it is everything this filesystem offers.
                guard retryOnInterrupt({ fsync(fd) }) == 0 else {
                    throw WriteError.syncFailed(path: path, errno: errno)
                }
                return
            default:
                throw WriteError.syncFailed(path: path, errno: errno)
            }
        }
    }

    /// `URL.resolvingSymlinksInPath()` gives up on a link whose target does not
    /// exist, which would leave us renaming over the link itself — exactly the
    /// case the symlink handling exists to avoid. Walk it by hand.
    private static func resolvingSymlink(_ path: String, depth: Int = 0) throws -> String {
        // Give up loudly. Returning the unresolved path would send the caller on
        // to `rename`, which replaces the link with a regular file — the exact
        // damage this resolution exists to prevent (found in review).
        guard depth < 16 else { throw WriteError.unresolvablePath(path) }
        var info = stat()
        while lstat(path, &info) != 0 {
            switch errno {
            case EINTR:
                continue
            case ENOENT:
                // Nothing there yet — a new file, not a link. Normal.
                return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            default:
                // "Cannot inspect" is not "ordinary file": treating it as one
                // would carry on to a rename that could clobber a link we simply
                // failed to read (found in review).
                throw WriteError.unresolvablePath(path)
            }
        }
        guard (info.st_mode & S_IFMT) == S_IFLNK else {
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let n = readlink(path, &buffer, buffer.count - 1)
        guard n > 0 else { throw WriteError.unresolvablePath(path) }
        buffer[n] = 0
        let destination = String(decoding: buffer[..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let resolved = destination.hasPrefix("/")
            ? destination
            : ((path as NSString).deletingLastPathComponent as NSString)
                .appendingPathComponent(destination)
        return try resolvingSymlink(resolved, depth: depth + 1)
    }

    private static func retryOnInterrupt(_ operation: () -> Int32) -> Int32 {
        while true {
            let result = operation()
            if result == 0 || errno != EINTR { return result }
        }
    }
}
