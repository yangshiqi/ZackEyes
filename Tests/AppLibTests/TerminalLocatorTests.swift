import Testing
@testable import AppLib

struct TerminalLocatorTests {

    // MARK: - isClaudeProcess

    @Test func nativeClaudeBinaryMatches() {
        #expect(TerminalLocator.isClaudeProcess(args: "claude"))
        #expect(TerminalLocator.isClaudeProcess(args: "/usr/local/bin/claude"))
        #expect(TerminalLocator.isClaudeProcess(args: "/opt/homebrew/bin/claude --resume"))
    }

    @Test func npmInstalledClaudeMatches() {
        // npm install runs claude as `node /path/to/claude-code/cli.js`
        let npmGlobal = "node /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"
        let npmLocal = "node /Users/foo/project/node_modules/@anthropic-ai/claude-code/dist/cli.js"
        #expect(TerminalLocator.isClaudeProcess(args: npmGlobal))
        #expect(TerminalLocator.isClaudeProcess(args: npmLocal))
    }

    @Test func vueDevServerDoesNotMatch() {
        // The exact false positive that Pete-from-The-Who tombstone hit:
        // a Vue CLI dev server running in /packages/web subdirectory.
        let vue = "node /Users/ysq/Work/rise/console-ui-new/packages/web/node_modules/.bin/../@vue/cli-service/bin/vue-cli-service.js serve"
        #expect(!TerminalLocator.isClaudeProcess(args: vue))
    }

    @Test func otherNodeToolsDoNotMatch() {
        let viteServer = "node /path/to/node_modules/vite/bin/vite.js"
        let webpack = "node /path/to/node_modules/webpack/bin/webpack.js"
        let jest = "node /path/to/node_modules/.bin/jest --watch"
        let plainNode = "node"
        let nodeRepl = "node -e \"console.log(1)\""
        #expect(!TerminalLocator.isClaudeProcess(args: viteServer))
        #expect(!TerminalLocator.isClaudeProcess(args: webpack))
        #expect(!TerminalLocator.isClaudeProcess(args: jest))
        #expect(!TerminalLocator.isClaudeProcess(args: plainNode))
        #expect(!TerminalLocator.isClaudeProcess(args: nodeRepl))
    }

    @Test func unrelatedProcessesDoNotMatch() {
        // Vim editing a file with "claude" in its name must NOT match —
        // we never look at argv[1] for non-node processes.
        #expect(!TerminalLocator.isClaudeProcess(args: "vim /tmp/claude-notes.md"))
        #expect(!TerminalLocator.isClaudeProcess(args: "/usr/bin/python3 script.py"))
        #expect(!TerminalLocator.isClaudeProcess(args: ""))
    }
}
