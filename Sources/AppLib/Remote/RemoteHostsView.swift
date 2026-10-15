import SwiftUI

struct RemoteHostsView: View {
    @ObservedObject var manager: RemoteHostManager
    @State private var editingID: UUID?
    @State private var name = ""
    @State private var destination = ""
    @State private var error: String?
    @State private var copiedInstallCommand = false
    var body: some View {
        let guide = RemoteSetupGuide(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String)
        VStack(alignment: .leading, spacing: 16) {
            Text(
                "See Claude and Codex sessions from another machine. Handle questions and approvals in its terminal."
            )
            .font(.system(size: 12)).foregroundStyle(.secondary)
            setupGuide(guide)
            Divider()
            if let message = manager.configurationError ?? error {
                Text(message).foregroundStyle(AppColors.attention.color).font(.system(size: 12))
            }
            if !manager.statuses.isEmpty {
                Text("Saved hosts").font(.headline)
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
                        Text(status.host.destination).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(
                                .secondary)
                        Text(status.label).font(.system(size: 11))
                            .foregroundStyle(
                                status.phase == .failed ? AppColors.attention.color : .secondary)
                        if status.phase == .failed {
                            Link("Troubleshoot SSH", destination: guide.documentationURL)
                                .font(.system(size: 11))
                        }
                    }.padding(12).background(
                        .white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }
                Divider()
            }
            Text(editingID == nil ? "3. Add your SSH host" : "Edit host").font(.headline)
            Text(
                "Use an existing SSH alias or user@hostname. Custom ports, keys and jump hosts belong in your SSH config."
            )
            .font(.system(size: 12)).foregroundStyle(.secondary)
            Text("Host name").font(.system(size: 12))
            TextField("e.g. Dev server", text: $name)
                .accessibilityLabel("Host name")
            Text("SSH address").font(.system(size: 12))
            TextField("SSH alias or user@hostname", text: $destination)
                .autocorrectionDisabled()
                .accessibilityLabel("SSH address")
            HStack {
                Button(editingID == nil ? "Add Host" : "Save Host") {
                    let existing = manager.statuses.first { $0.id == editingID }?.host
                    perform {
                        try manager.saveHost(
                            RemoteHost(
                                id: editingID ?? UUID(),
                                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                destination: destination.trimmingCharacters(
                                    in: .whitespacesAndNewlines),
                                enabled: existing?.enabled ?? true))
                        clearEditor()
                    }
                }
                .disabled(
                    manager.configurationError != nil
                        || (editingID == nil && manager.statuses.count >= 8))
                if editingID != nil { Button("Cancel", action: clearEditor) }
            }
            Text(
                "Recent transcript observations: Claude 8 hours · Codex 30 minutes. An observed session does not prove a remote process is still running."
            )
            .font(.system(size: 11)).foregroundStyle(.secondary)

        }
    }
    private func setupGuide(_ guide: RemoteSetupGuide) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("1. Install the remote helper").font(.headline)
            Text("Run this on the remote machine, using the same account as Claude/Codex.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if let command = guide.installCommand {
                Text(command)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            } else {
                Text("Choose the helper matching your app version from Downloads.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                if let command = guide.installCommand {
                    Button(copiedInstallCommand ? "Copied" : "Copy install command") {
                        NSPasteboard.general.clearContents()
                        copiedInstallCommand = NSPasteboard.general.setString(
                            command, forType: .string)
                    }
                }
                Link("Download helper", destination: guide.downloadURL)
                    .help("Open this release’s helper packages and SHA256 checksums")
                Link("Setup guide", destination: guide.documentationURL)
            }
            Text(
                "Linux or macOS 14+ · x86_64 or arm64. No Swift, Git or sudo needed. The installer verifies SHA256."
            )
            .font(.system(size: 11)).foregroundStyle(.secondary)
            Text("2. Verify SSH from this Mac").font(.headline).padding(.top, 4)
            Text(
                "Confirm key-based login with ssh your-host and verify the host key in your terminal. Then test:"
            )
            .font(.system(size: 12)).foregroundStyle(.secondary)
            Text("ssh your-host '~/.local/bin/zackeyes --stream'")
                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            Text(
                "JSON output every five seconds means the helper is connected. Press Control-C to stop the test."
            )
            .font(.system(size: 12)).foregroundStyle(.secondary)
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
            Text(
                "Last activity \(max(0, Int(now.timeIntervalSince(session.lastActiveAt) / 60)))m ago"
            )
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
