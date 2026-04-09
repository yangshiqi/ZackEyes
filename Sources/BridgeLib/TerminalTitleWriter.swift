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
}
