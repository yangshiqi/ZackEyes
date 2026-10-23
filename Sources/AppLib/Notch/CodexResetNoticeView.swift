import SwiftUI

/// Shared by the physical notch, simulated notch and menu-bar fallback.
/// Kept outside the quota bars so a public announcement cannot look like an
/// account-specific 5h/7d refresh reading.
struct CodexResetNoticeView: View {
    let announcement: CodexResetAnnouncement

    private var title: String {
        announcement.kind == .banked ? "Banked reset" : "Extra Codex reset"
    }

    private func timing(at now: Date) -> String {
        if let delivered = announcement.reportedDeliveredAt {
            return "Reported delivered \(delivered.formatted(date: .abbreviated, time: .shortened))"
        }
        if let expectedAt = announcement.expectedAt {
            let time = expectedAt.formatted(date: .abbreviated, time: .shortened)
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

    private var details: String {
        let posted = announcement.announcedAt.formatted(date: .abbreviated, time: .shortened)
        let window = announcement.expectedWindowText.map { " Source timing: \($0)." } ?? ""
        return "Public announcement via CodexReset. \(announcement.scope). Posted \(posted) local.\(window) Check Codex /usage for your account."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                Text(title).fontWeight(.semibold)
                Spacer(minLength: 4)
                Text("CodexReset")
                    .foregroundStyle(.white.opacity(0.55))
                Link(destination: announcement.sourceURL) {
                    Image(systemName: "arrow.up.right.square")
                }
                .help("Open original announcement via CodexReset")
            }
            .font(.system(size: 11))
            .foregroundStyle(.white)

            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(timing(at: context.date))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
            }
            Text("Announced \(announcement.announcedAt.formatted(date: .abbreviated, time: .shortened)) local")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.65))
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .help(details)
    }
}
