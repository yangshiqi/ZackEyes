import AppKit

/// Small application command menu for the status-bar icon. Preferences live
/// in the shared Settings window; this menu is only a gateway plus app-level
/// commands that must remain reachable when the notch is hidden.
@MainActor
public final class StatusBarMenu: NSObject {
    private let updateChecker: UpdateChecker
    private let downloader: UpdateDownloader
    private let journalTrigger: JournalManualTrigger
    private var aboutWindow: AboutWindow?

    public init(updateChecker: UpdateChecker, downloader: UpdateDownloader,
                journalTrigger: JournalManualTrigger) {
        self.updateChecker = updateChecker
        self.downloader = downloader
        self.journalTrigger = journalTrigger
        super.init()
    }

    public func build() -> NSMenu {
        let menu = NSMenu()

        if let version = updateChecker.availableVersion {
            let (title, enabled) = Self.updateMenuLabel(version: version, state: downloader.state)
            let update = NSMenuItem(
                title: title,
                action: enabled ? #selector(updateClicked(_:)) : nil,
                keyEquivalent: ""
            )
            update.target = enabled ? self : nil
            update.isEnabled = enabled
            menu.addItem(update)
            menu.addItem(.separator())
        }

        let settings = NSMenuItem(
            title: "Settings...",
            action: #selector(settingsClicked(_:)),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        let about = NSMenuItem(
            title: "About ZackEyes",
            action: #selector(aboutClicked(_:)),
            keyEquivalent: ""
        )
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())

        // #214 P1 — manual trigger; the nightly scheduler is P3. The menu is
        // rebuilt on every open, so the label tracks the trigger's state.
        let (journalTitle, journalEnabled) =
            JournalManualTrigger.menuLabel(for: journalTrigger.state)
        let journal = NSMenuItem(
            title: journalTitle,
            action: journalEnabled ? #selector(journalClicked(_:)) : nil,
            keyEquivalent: ""
        )
        journal.target = journalEnabled ? self : nil
        journal.isEnabled = journalEnabled
        menu.addItem(journal)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit ZackEyes",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApp
        menu.addItem(quit)
        return menu
    }

    @objc private func settingsClicked(_ sender: Any?) {
        NotificationCenter.default.post(name: .settingsWindowRequested, object: nil)
    }

    @objc private func journalClicked(_ sender: Any?) {
        journalTrigger.generateToday()
    }

    @objc private func aboutClicked(_ sender: Any?) {
        if aboutWindow == nil {
            aboutWindow = AboutWindow()
        }
        aboutWindow?.show()
    }

    @objc private func updateClicked(_ sender: Any?) {
        if let dmgURL = updateChecker.dmgURL {
            Task { @MainActor in await downloader.download(from: dmgURL) }
        } else if let releaseURL = updateChecker.releaseURL {
            NSWorkspace.shared.open(releaseURL)
        }
    }

    public static func updateMenuLabel(
        version: String,
        state: UpdateDownloader.State
    ) -> (title: String, enabled: Bool) {
        switch state {
        case .idle:
            return ("Update Available (v\(version))", true)
        case .downloading:
            return ("Downloading v\(version)…", false)
        case .ready:
            return ("Update Ready (v\(version)) — Click to Open", true)
        case .failed:
            return ("Update Failed — Click to Retry", true)
        }
    }
}
