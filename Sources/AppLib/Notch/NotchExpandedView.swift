import SwiftUI

struct NotchExpandedView: View {
    @ObservedObject var viewModel: NotchViewModel
    @State private var pulseOpacity: Double = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 8) {
                Circle()
                    .fill(viewModel.statusColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: viewModel.statusColor, radius: 3)
                    .opacity(viewModel.sessionStore.state == .waiting ? pulseOpacity : 1.0)
                    .onAppear {
                        withAnimation(
                            .easeInOut(duration: 0.9)
                            .repeatForever(autoreverses: true)
                        ) {
                            pulseOpacity = 0.3
                        }
                    }

                Text("Claude Code")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)

                Spacer()

                Text(viewModel.statusText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(viewModel.statusColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(viewModel.statusColor.opacity(0.15))
                    .clipShape(Capsule())
            }

            // CWD
            if let cwd = viewModel.sessionStore.cwd {
                Text(cwd)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.gray)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            // Permission request section
            if let pending = viewModel.sessionStore.pendingPermission {
                Divider()
                    .background(Color.white.opacity(0.1))

                VStack(alignment: .leading, spacing: 8) {
                    Text("PERMISSION REQUEST")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.gray)
                        .kerning(0.5)

                    Text(pending.toolName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color(red: 0.96, green: 0.65, blue: 0.14))

                    if let preview = toolInputPreview(pending) {
                        Text(preview)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.white.opacity(0.8))
                            .lineLimit(3)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.05))
                            .cornerRadius(6)
                    }

                    HStack(spacing: 8) {
                        Button(action: { viewModel.deny() }) {
                            Text("Deny")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.red)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(Color.red.opacity(0.15))
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)

                        Button(action: { viewModel.approve() }) {
                            Text("Allow Once")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Color(red: 0.31, green: 0.80, blue: 0.77))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(Color(red: 0.31, green: 0.80, blue: 0.77).opacity(0.15))
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func toolInputPreview(_ pending: PendingPermission) -> String? {
        if let command = pending.toolInput["command"] as? String {
            return command
        }
        if let filePath = pending.toolInput["file_path"] as? String {
            return filePath
        }
        return nil
    }
}
