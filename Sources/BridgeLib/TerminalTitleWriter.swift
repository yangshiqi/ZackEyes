import Foundation
import Shared

/// Writes OSC 2 tab titles (and manages the prompt cache) for terminal
/// emulators that support title escape sequences (primarily Ghostty).
///
/// Split into pure helpers (`sanitizePrompt`, `truncateToChars`,
/// `formatTitle`, `oscEscape`) and IO (`TitleCache`, `writeIfPossible`).
/// The pure helpers are exhaustively unit-tested; the IO pieces have
/// a small integration shim.
///
/// This file starts with the pure helpers only. TitleCache (Task 3) and
/// writeIfPossible (Task 4) are added in follow-up tasks.
public enum TerminalTitleWriter {

    /// Strip C0 control characters (ESC, BEL, etc.) and replace newlines/tabs
    /// with spaces. Defensive against prompt content that contains terminal
    /// escape sequences which would re-interpret our outer OSC 2 wrapper.
    public static func sanitizePrompt(_ input: String) -> String {
        var out = ""
        out.reserveCapacity(input.count)
        for scalar in input.unicodeScalars {
            let value = scalar.value
            if scalar == "\n" || scalar == "\r" || scalar == "\t" {
                out.append(" ")
            } else if value < 0x20 || value == 0x7F {
                // other C0 / DEL — drop entirely
                continue
            } else {
                out.append(Character(scalar))
            }
        }
        return out
    }

    /// Truncate by character count (Swift `Character`, i.e. grapheme cluster),
    /// not by UTF-8 byte. CJK-friendly.
    public static func truncateToChars(_ input: String, max: Int) -> String {
        guard input.count > max else { return input }
        return String(input.prefix(max))
    }

    /// Compose the tab title.
    /// Format with prompt:    `{basename} · {sanitized prompt[:30]} · ze:{sid[:8]}`
    /// Format without prompt: `{basename} · ze:{sid[:8]}`
    public static func formatTitle(
        cwd: String,
        sessionId: String,
        prompt: String?
    ) -> String {
        let basename = (cwd as NSString).lastPathComponent
        let sidShort = String(sessionId.prefix(8))
        if let raw = prompt, !raw.isEmpty {
            let clean = truncateToChars(sanitizePrompt(raw), max: 30)
            if !clean.isEmpty {
                return "\(basename) · \(clean) · ze:\(sidShort)"
            }
        }
        return "\(basename) · ze:\(sidShort)"
    }

    /// OSC 2 ("set window title") escape sequence:
    /// `ESC ] 2 ; <title> BEL`
    public static func oscEscape(title: String) -> String {
        "\u{001B}]2;\(title)\u{0007}"
    }

    /// Fire-and-forget OSC 2 write. Silent on every failure path.
    /// Sequence of operations:
    ///   1. Resolve tty from `ppid` (Bridge's parent = claude PID). nil → return.
    ///   2. If `prompt` given and cache file missing → write cache (first wins).
    ///   3. Read cached prompt (may be nil).
    ///   4. Compose title + OSC 2.
    ///   5. Open /dev/ttys… for write, write bytes, close. Silent on error.
    public static func writeIfPossible(
        sessionId: String?,
        cwd: String?,
        prompt: String?,
        ppid: Int32,
        cache: TitleCache = TitleCache()
    ) {
        guard let sid = sessionId, !sid.isEmpty,
              let cwd = cwd, !cwd.isEmpty,
              let tty = TTYUtil.ttyPath(pid: ppid) else {
            return
        }

        // Cache the first prompt if we have one and none is stored yet
        if let p = prompt, !p.isEmpty {
            let sanitized = sanitizePrompt(p)
            let clipped = truncateToChars(sanitized, max: 30)
            if !clipped.isEmpty {
                cache.writeIfMissing(sessionId: sid, content: clipped)
            }
        }

        let cachedPrompt = cache.read(sessionId: sid)
        let title = formatTitle(cwd: cwd, sessionId: sid, prompt: cachedPrompt)
        let osc   = oscEscape(title: title)
        guard let data = osc.data(using: .utf8) else { return }

        // Open tty, write, close. Every error path is silent.
        guard let fh = FileHandle(forWritingAtPath: tty) else {
            NSLog("ZackEyes: TitleWriter open-fail tty=%{public}@ sid=%{public}@", tty, sid)
            return
        }
        do {
            try fh.write(contentsOf: data)
            try fh.close()
            NSLog("ZackEyes: TitleWriter tty=%{public}@ sid=%{public}@ bytes=%d ok=1", tty, sid, data.count)
        } catch {
            NSLog("ZackEyes: TitleWriter write-fail tty=%{public}@ sid=%{public}@ err=%{public}@", tty, sid, "\(error)")
        }
    }
}

/// Disk cache of the first user prompt per session, used by
/// `TerminalTitleWriter` to keep tab titles stable once set.
///
/// - Directory: `~/.zackeyes/osc2-titles/` by default
/// - Filename: first 16 ASCII chars of the session UUID
/// - Content: UTF-8 plain text, the (sanitized, truncated) first prompt
public struct TitleCache {
    public let directory: String

    public static let defaultDirectory: String = {
        let home = NSHomeDirectory()
        return (home as NSString).appendingPathComponent(".zackeyes/osc2-titles")
    }()

    public init(directory: String = TitleCache.defaultDirectory) {
        self.directory = directory
    }

    public func read(sessionId: String) -> String? {
        let path = filePath(for: sessionId)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    /// Atomic first-write-wins: write only if the file does not yet exist.
    /// Silent on all errors (the title feature is fire-and-forget).
    public func writeIfMissing(sessionId: String, content: String) {
        let path = filePath(for: sessionId)
        if FileManager.default.fileExists(atPath: path) { return }

        // Ensure parent dir exists
        try? FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        try? content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func filePath(for sessionId: String) -> String {
        let safe = String(sessionId.prefix(16))
        return (directory as NSString).appendingPathComponent(safe)
    }
}
