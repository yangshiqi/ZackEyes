import Testing
@testable import AppLib

@MainActor
@Test func statusBarMenuBuildsTheApplicationCommands() {
    let menu = StatusBarMenu(
        updateChecker: UpdateChecker(checkInterval: 60),
        downloader: UpdateDownloader(),
        journalTrigger: JournalManualTrigger()
    ).build()

    let commandTitles = menu.items
        .filter { !$0.isSeparatorItem }
        .map(\.title)

    #expect(commandTitles == [
        "Settings...", "About ZackEyes",
        "Generate Today's Journal", "Quit ZackEyes",
    ])
}
