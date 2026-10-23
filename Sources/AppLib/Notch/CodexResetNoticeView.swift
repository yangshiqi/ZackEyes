import SwiftUI

/// Shared by the physical notch, simulated notch and menu-bar fallback.
/// Kept outside the quota bars so a public announcement cannot look like an
/// account-specific 5h/7d refresh reading.
struct CodexResetNoticeView: View {
    let announcement: CodexResetAnnouncement

    private var title: String {
        let what = announcement.kind == .banked ? "Banked reset" : "Extra Codex reset"
        switch announcement.phase {
        case .scheduled: return "\(what) announced"
        case .announced: return "\(what) announcement"
        case .reportedComplete: return "\(what) reported delivered"
        }
    }

    private func timing(at now: Date) -> String {
        if let delivered = announcement.reportedDeliveredAt {
            return "Reported delivered \(delivered.formatted(date: .abbreviated, time: .shortened)) local"
        }
        if let expectedAt = announcement.expectedAt {
            let time = expectedAt.formatted(date: .abbreviated, time: .shortened)
            if let countdown = announcement.countdown(at: now) {
                return "Expected \(time) local · \(countdown)"
            }
            return "Expected \(time) local · time passed, check /usage"
        }
        if let day = announcement.expectedDay {
            if let window = announcement.expectedWindowText {
                return "Expected \(day) · \(window) (source timing)"
            }
            return "Expected day: \(day) (source calendar date)"
        }
        return "Announced \(announcement.announcedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                Text(title).fontWeight(.semibold)
                Spacer(minLength: 4)
                Link(destination: announcement.sourceURL) {
                    Image(systemName: "arrow.up.right.square")
                }
                .help("Open original announcement")
            }
            .font(.system(size: 11))
            .foregroundStyle(.white)

            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(timing(at: context.date))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.8))
            }
            if announcement.phase != .announced {
                Text("Announced \(announcement.announcedAt.formatted(date: .abbreviated, time: .shortened)) local")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.65))
            }
            HStack(spacing: 3) {
                Text("\(announcement.scope) · Public announcement via")
                Link("CodexReset", destination: URL(string: "https://codexreset.ai/")!)
            }
            .font(.system(size: 9))
            .foregroundStyle(.white.opacity(0.6))
            Text("Check Codex /usage for your account. Updated \(announcement.providerUpdatedAt.formatted(date: .omitted, time: .shortened)).")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
}
