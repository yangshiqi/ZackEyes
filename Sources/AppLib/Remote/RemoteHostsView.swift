import SwiftUI

struct RemoteHostsView: View {
    @ObservedObject var manager: RemoteHostManager
    @State private var editingID: UUID?
    @State private var name = ""
    @State private var destination = ""
    @State private var error: String?
    var body: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.10.0"
        let installCommand = "curl -fsSL https://github.com/yangshiqi/ZackEyes-release/releases/download/v\(version)/install-remote.sh | sh -s -- \(version)"
        VStack(alignment: .leading, spacing: 16) {
            Text("Observe Claude and Codex on your SSH hosts. Requests must be handled in the remote terminal.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if let message = manager.configurationError ?? error {
                Text(message).foregroundStyle(AppColors.attention.color).font(.system(size: 12))
            }
            ForEach(manager.statuses) { status in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Toggle(
                            status.host.name,
                            isOn: Binding(
                                get: { status.host.enabled },
                                set: { enabled in
                                    var host = status.host
                                    host.enabled = enabled
                                    perform { try manager.saveHost(host) }
                                }))
                        Spacer()
                        Button("Edit") {
                            editingID = status.id
                            name = status.host.name
                            destination = status.host.destination
                        }
                        .accessibilityLabel("Edit \(status.host.name)")
                        Button("Remove") {
                            perform { try manager.removeHost(status.id) }
                            if editingID == status.id { clearEditor() }
                        }
                        .accessibilityLabel("Remove \(status.host.name)")
                    }
                    Text(status.host.destination).font(.system(size: 11, design: .monospaced)).foregroundStyle(
                        .secondary)
                    Text(status.label).font(.system(size: 11))
                        .foregroundStyle(status.phase == .failed ? AppColors.attention.color : .secondary)
                }.padding(12).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
            Divider()
            Text(editingID == nil ? "Add host" : "Edit host").font(.headline)
            TextField("Host name", text: $name)
            TextField("SSH alias or user@hostname", text: $destination)
                .autocorrectionDisabled()
            HStack {
                Button(editingID == nil ? "Add Host" : "Save Host") {
                    let existing = manager.statuses.first { $0.id == editingID }?.host
                    perform {
                        try manager.saveHost(
                            RemoteHost(
                                id: editingID ?? UUID(),
                                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                destination: destination.trimmingCharacters(in: .whitespacesAndNewlines),
                                enabled: existing?.enabled ?? true))
                        clearEditor()
                    }
                }
                .disabled(manager.configurationError != nil || (editingID == nil && manager.statuses.count >= 8))
                if editingID != nil { Button("Cancel", action: clearEditor) }
            }
            Divider()
            Text("Setup").font(.headline)
            Text(
                "Run this command on the remote host as the user running Claude/Codex. It downloads the matching prebuilt helper, verifies SHA256 and installs ~/.local/bin/zackeyes. No Swift, Git or sudo required. Supports Linux and macOS 14+, x86_64 and arm64."
            )
            .font(.system(size: 12)).foregroundStyle(.secondary)
            Text(installCommand)
                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            Text("Then verify key authentication and trust the host key in your terminal. ZackEyes never opens password prompts or changes your SSH configuration.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Text("ssh your-host '~/.local/bin/zackeyes --stream'")
                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            Text(
                "Recent transcript observations: Claude 8 hours · Codex 30 minutes. An observed session does not prove a remote process is still running."
            )
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func clearEditor() {
        editingID = nil
        name = ""
        destination = ""
    }
}

struct RemoteSessionCard: View {
    let session: SessionInfo
    let now: Date
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Image(systemName: "network")
                Text(session.displayName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                AgentBadge(agent: session.agent)
            }
            Text(
                "\(session.remoteHostName ?? "Remote host") · \(session.remoteObservedState?.rawValue ?? "unknown") · observed"
            )
            .font(.system(size: 11)).foregroundStyle(.secondary)
            if let model = session.modelDisplayName {
                Text(model).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if let tool = session.currentToolName {
                Text(tool).font(.system(size: 11, design: .monospaced)).lineLimit(1)
            }
            Text("Last activity \(max(0, Int(now.timeIntervalSince(session.lastActiveAt) / 60)))m ago")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if session.state == .waiting {
                Text("Needs attention in the remote terminal")
                    .font(.system(size: 11)).foregroundStyle(AppColors.attention.color)
            }
            if let error = session.errorMessage {
                Text(error).font(.system(size: 11)).foregroundStyle(AppColors.critical.color)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }
}
