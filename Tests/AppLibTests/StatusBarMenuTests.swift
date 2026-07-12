import Testing
@testable import AppLib

@MainActor
@Test func statusBarMenuBuildsTheThreeApplicationCommands() {
    let menu = StatusBarMenu(
        updateChecker: UpdateChecker(checkInterval: 60),
        downloader: UpdateDownloader()
    ).build()

    let commandTitles = menu.items
        .filter { !$0.isSeparatorItem }
        .map(\.title)

    #expect(commandTitles == ["Settings...", "About ZackEyes", "Quit ZackEyes"])
}
