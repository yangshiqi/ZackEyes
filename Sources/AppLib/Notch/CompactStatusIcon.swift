import Shared
import SwiftUI

struct CompactAttention: Equatable {
    enum Kind: Equatable {
        case none
        case pending
        case error
    }

    let kind: Kind
    let count: Int

    static func make(from sessions: [SessionInfo]) -> Self {
        let attentionSessions = sessions.filter {
            $0.pendingPermission != nil || $0.errorMessage != nil || $0.state == .waiting
        }
        let hasError = attentionSessions.contains { $0.errorMessage != nil }
        let kind: Kind = attentionSessions.isEmpty ? .none : (hasError ? .error : .pending)
        return Self(kind: kind, count: attentionSessions.count)
    }
}

struct CompactStatusIcon: View {
    let attention: CompactAttention
    let aggregateState: SessionState
    let workingColor: Color

    var body: some View {
        HStack(spacing: 2) {
            statusSymbol
            if attention.count > 1 {
                Text("\(attention.count)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(statusColor)
            }
        }
        .frame(width: 24, height: 14, alignment: .leading)
    }

    @ViewBuilder
    private var statusSymbol: some View {
        switch attention.kind {
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(statusColor)
        case .pending:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 11))
                .foregroundColor(statusColor)
        case .none:
            switch aggregateState {
            case .working:
                Circle()
                    .fill(workingColor)
                    .frame(width: 8, height: 8)
            case .idle, .stopped:
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35))
            case .waiting:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(AppColors.attention.color)
            }
        }
    }

    private var statusColor: Color {
        attention.kind == .error
            ? AppColors.critical.color
            : AppColors.attention.color
    }
}
