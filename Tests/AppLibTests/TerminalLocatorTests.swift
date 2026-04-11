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

    @Test func npmClaudeWithNodeFlagsStillMatches() {
        // node interpreter flags push the script path past argv[1].
        // The matching must scan all subsequent tokens, not just argv[1].
        let withInspect = "node --inspect /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"
        let withMemFlag = "node --max-old-space-size=4096 /opt/claude-code/cli.js --resume"
        let withMultiple = "node --inspect-brk --enable-source-maps /path/claude-code/cli.js"
        #expect(TerminalLocator.isClaudeProcess(args: withInspect))
        #expect(TerminalLocator.isClaudeProcess(args: withMemFlag))
        #expect(TerminalLocator.isClaudeProcess(args: withMultiple))
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

    @Test func userNamedClaudeDoesNotFalseMatch() {
        // A user whose UNIX home dir is /Users/claude running a node script
        // must NOT be counted as a claude process. This was a real concern
        // with the loose `/claude` substring rule we had earlier.
        #expect(!TerminalLocator.isClaudeProcess(args: "node /Users/claude/server.js"))
        #expect(!TerminalLocator.isClaudeProcess(args: "node /home/claude/projects/api/dist/index.js"))
    }

    @Test func projectsNamedClaudeDoNotFalseMatch() {
        // Projects with `claude` in their directory name (but not the
        // official `claude-code/` package) must NOT match.
        #expect(!TerminalLocator.isClaudeProcess(args: "node /Users/foo/claude-wrapper/index.js"))
        #expect(!TerminalLocator.isClaudeProcess(args: "node /Users/foo/my-claude-app/server.js"))
        #expect(!TerminalLocator.isClaudeProcess(args: "node /tmp/claude-test.js"))
    }

    @Test func hypotheticalClaudeJsEntryPointMatches() {
        // /claude.js exact filename and /…/claude (no extension) — these
        // are explicit entry-point shapes the matcher accepts.
        #expect(TerminalLocator.isClaudeProcess(args: "node /usr/local/lib/claude.js"))
        #expect(TerminalLocator.isClaudeProcess(args: "node /opt/anthropic/bin/claude"))
    }
}
