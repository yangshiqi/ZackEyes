import AppKit
import SwiftUI

enum CodexResetTimeText {
    static func local(
        _ date: Date,
        timeZone: TimeZone = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let clock = date.formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: timeZone)
                .locale(locale)
        )
        let offset = timeZone.secondsFromGMT(for: date)
        let hours = abs(offset) / 3600
        let minutes = (abs(offset) % 3600) / 60
        let minuteText = minutes == 0 ? "" : ":\(minutes < 10 ? "0" : "")\(minutes)"
        return "\(clock) UTC\(offset >= 0 ? "+" : "-")\(hours)\(minuteText)"
    }
}

/// Shared by the physical notch, simulated notch and menu-bar fallback.
/// Kept outside the quota bars so a public announcement cannot look like an
/// account-specific 5h/7d refresh reading.
struct CodexResetNoticeView: View {
    let announcement: CodexResetAnnouncement

    @State private var showingOriginal = false
    @State private var hoveringOriginal = false
    @State private var hoveringPopover = false
    @State private var dismissTask: Task<Void, Never>?

    private var title: String {
        announcement.kind == .banked ? "Banked reset" : "Extra Codex reset"
    }

    private func timing(at now: Date) -> String {
        if let delivered = announcement.reportedDeliveredAt {
            return "Reported delivered \(CodexResetTimeText.local(delivered))"
        }
        if let expectedAt = announcement.expectedAt {
            let time = CodexResetTimeText.local(expectedAt)
            if let countdown = announcement.countdown(at: now) {
                return "Expected \(time) · \(countdown)"
            }
            return "Expected \(time) · time passed"
        }
        if let day = announcement.expectedDay {
            return "Expected \(day) · time not specified"
        }
        return "Reset time not announced"
    }

    func header(at now: Date) -> String {
        "\(title) - \(timing(at: now))"
    }

    private var originalText: String {
        announcement.originalText ?? "Original announcement text unavailable. Open the original post."
    }

    private var originalTextPreview: String {
        String(decoding: originalText.utf8.prefix(4096), as: UTF8.self)
    }

    private var originalTextHeight: CGFloat {
        let size = (originalTextPreview as NSString).boundingRect(
            with: NSSize(width: 336, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 12)]
        ).size
        return min(280, ceil(size.height) + 28)
    }

    private func updateHover(_ hovering: Bool, inPopover: Bool = false) {
        if inPopover { hoveringPopover = hovering } else { hoveringOriginal = hovering }
        dismissTask?.cancel()
        if hoveringOriginal || hoveringPopover {
            showingOriginal = true
        } else {
            dismissTask = Task { @MainActor in
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                showingOriginal = false
            }
        }
    }

    private var details: String {
        let posted = CodexResetTimeText.local(announcement.announcedAt)
        let window = announcement.expectedWindowText.map { " Source timing: \($0)." } ?? ""
        return "Public announcement via CodexReset. \(announcement.scope). Posted \(posted).\(window) Check Codex /usage for your account."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                HStack(spacing: 5) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text(header(at: context.date))
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .help(header(at: context.date))
                    Spacer(minLength: 4)
                    Link(destination: announcement.sourceURL) {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .help("Open original announcement")
                }
                .font(.system(size: 11))
                .foregroundStyle(.white)
                .frame(height: 14)
            }
            Text(verbatim: originalTextPreview)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(2, reservesSpace: true)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(CodexResetOriginalTextPopover(
                    text: originalText, height: originalTextHeight,
                    isPresented: showingOriginal,
                    onHover: { updateHover($0, inPopover: true) },
                    onAnchorHover: { updateHover($0) }
                ))
            Text("Announced \(CodexResetTimeText.local(announcement.announcedAt))")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.65))
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityHint(details)
        .onChange(of: showingOriginal) { _, visible in
            if !visible { hoveringPopover = false }
        }
        .onDisappear {
            dismissTask?.cancel()
            hoveringOriginal = false
            hoveringPopover = false
            showingOriginal = false
        }
    }
}
