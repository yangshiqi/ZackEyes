import Testing
import Foundation
@testable import AppLib

/// #214 — the journal's only safety boundary.
///
/// The design removed the human review gate, so nothing else stands between a
/// model's output and a git push. That makes two kinds of test equally
/// load-bearing:
///
/// 1. **Leaks are caught.** The obvious half.
/// 2. **Ordinary sentences survive.** The half that gets skipped. A sanitizer
///    that quietly eats normal prose fails silently — the user just watches
///    the journal get thinner and concludes the feature is broken. There is no
///    error to notice, which makes it worse than a crash, not better.
struct JournalSanitizerTests {

    private let policy = JournalSanitizer.Policy(
        maxScalars: 200,
        forbiddenLiterals: ["/Users/testuser", "testuser", "test-macbook"]
    )

    private func rejection(_ s: String) -> JournalSanitizer.Rejection? {
        switch JournalSanitizer.check(s, policy: policy) {
        case .success: return nil
        case .failure(let r): return r
        }
    }

    // MARK: - False positives (the half that gets skipped)

    @Test("ordinary Chinese work notes all survive")
    func ordinaryChineseSurvives() {
        let corpus = [
            "修复了权限审批串号的问题，改成按请求 id 关联。",
            "今天推进了 3 个项目，其中 2 个已交付。",
            "和上游确认了压缩的时序，写进了设计稿。",
            "重构了配额读取逻辑（拆成两层），测试全绿。",
            "花了大半天排查偶发失败的测试，还没有结论。",
            "把端口探测从子进程换成系统调用，快了大约 50 倍。",
            "评审提了 12 条意见，接受 4 条，其余判为臆想。",
            "补了实机验证，确认徽章在 60 秒后按预期消失。",
        ]
        for line in corpus {
            #expect(rejection(line) == nil, "should survive: \(line)")
        }
    }

    @Test("ordinary English work notes all survive")
    func ordinaryEnglishSurvives() {
        let corpus = [
            "Fixed the permission approval race by keying on request id.",
            "Shipped the port badge and verified it on a real machine.",
            "Investigated why the panel collapsed on scroll; no fix yet.",
            "Reviewed 12 findings, accepted 4, rejected 8 as speculative.",
            "Spent most of the day on flaky test triage.",
            "Wrote the design doc and got it reviewed twice.",
            "Cut the release, then swept the site for stale copy.",
            "Measured it at 2.5 seconds, down from 11 seconds.",
        ]
        for line in corpus {
            #expect(rejection(line) == nil, "should survive: \(line)")
        }
    }

    @Test("mixed CJK and Latin survives")
    func mixedScriptSurvives() {
        #expect(rejection("把 ZackEyes 的压缩标记接到 GitHub 上，验证通过。") == nil)
        #expect(rejection("给 macOS 14 补了一版兼容处理。") == nil)
    }

    @Test("decimals survive but IP addresses do not")
    func decimalsSurviveIPsDoNot() {
        // The dotted-identifier rule requires a letter touching the dot, which
        // is what keeps a decimal alive. An IPv4 has digits on both sides of
        // every dot, so it needs its own rule.
        #expect(rejection("耗时 2.5 小时，比上次快了 1.5 倍。") == nil)
        #expect(rejection("Took 2.5 hours, about 1.5x faster.") == nil)
        #expect(rejection("连到 10.0.0.1 之后就卡住了。") == .ipAddress)
        #expect(rejection("Pointed it at 192.168.1.20 instead.") == .ipAddress)
    }

    @Test("issue references pass, stray hashes do not")
    func issueReferencesPass() {
        #expect(rejection("按 #214 的设计稿实现了提炼管道。") == nil)
        #expect(rejection("Closed #37 and #42 in the same release.") == nil)
        #expect(rejection("加了个 # 标题试试") == .strayHash)
        #expect(rejection("Used #hashtag style") == .strayHash)
    }

    // MARK: - Secrets

    @Test("credential prefixes are rejected as secrets, not as punctuation")
    func secretPrefixesRejected() {
        // Reported as `.secretPrefix` even when the character rule would also
        // have fired — a run record saying `disallowedCharacter` would be
        // useless for the one thing anyone greps it for.
        let secrets = [
            "token ghp_AbCdEfGhIjKlMnOpQrStUvWxYz01",
            "used github_pat_11ABCDEFG0abcdefgh",
            "key sk-abcdefghijklmnopqrst",
            "anthropic sk-ant-api03-xyz",
            "aws AKIAIOSFODNN7EXAMPLE",
            "slack xoxb-123456789012",
            "jwt eyJhbGciOiJIUzI1NiJ9",
            "pem -----BEGIN RSA PRIVATE KEY",
        ]
        for s in secrets {
            #expect(rejection(s) == .secretPrefix, "should be a secret: \(s)")
        }
    }

    @Test("a long opaque mixed run is rejected even without a known prefix")
    func highEntropyRejected() {
        #expect(rejection("deploy key was a1b2c3d4e5f6g7h8i9j0k1l2") == .highEntropy)
        // A long *word* with no digits is just a long word.
        #expect(rejection("Discussed internationalization at length today.") == nil)
    }

    // MARK: - Paths, code, identity

    @Test("path-shaped text is rejected")
    func pathsRejected() {
        let paths = [
            "改了 Sources/AppLib/Journal/Foo.swift",
            "ran make release from the repo root and it worked",   // control: survives
            "wrote to ~/.zackeyes/journal",
            "opened C:\\Users\\bob\\notes",
            "see docs/superpowers/specs for the design",
            "the file is called Redactor.swift",
        ]
        #expect(rejection(paths[0]) != nil)
        #expect(rejection(paths[1]) == nil)
        #expect(rejection(paths[2]) != nil)
        #expect(rejection(paths[3]) != nil)
        #expect(rejection(paths[4]) != nil)
        #expect(rejection(paths[5]) == .dottedIdentifier)
    }

    @Test("domains and URLs are rejected")
    func domainsRejected() {
        #expect(rejection("调用了 api.example.com 的接口") == .dottedIdentifier)
        #expect(rejection("Fetched from internal.corp.example") == .dottedIdentifier)
    }

    @Test("camelCase identifiers are rejected unless they are proper nouns")
    func camelCaseRejectedUnlessWhitelisted() {
        #expect(rejection("重写了 sessionStore 的合并逻辑") == .codeIdentifier)
        #expect(rejection("Renamed getUserName to something clearer") == .codeIdentifier)
        // Whitelisted product names must survive — they are exactly the names
        // a journal is expected to contain.
        #expect(rejection("给 ZackEyes 加了 GitHub 推送") == nil)
        #expect(rejection("Built it with SwiftUI on macOS") == nil)
    }

    @Test("a user-supplied project alias survives the camel-case rule")
    func userAliasSurvives() {
        // The user chose the alias precisely so it could appear in the journal.
        let custom = JournalSanitizer.Policy(
            maxScalars: 200,
            properNouns: JournalSanitizer.defaultProperNouns.union(["AcmeWidget"])
        )
        #expect(JournalSanitizer.sanitize("推进了 AcmeWidget 的接入", policy: custom) != nil)
        #expect(JournalSanitizer.sanitize("推进了 OtherThing 的接入", policy: custom) == nil)
    }

    @Test("home directory, username and hostname are discarded, not rewritten")
    func identityLiteralsDiscarded() {
        // Redactor's rules, Redactor's opposite semantics: a diagnostics dump
        // substitutes `<user>`; a journal line drops entirely, because a
        // sentence with a redaction marker wedged into it reads like an
        // incident and was never worth that much.
        #expect(rejection("moved it under /Users/testuser today") == .forbiddenLiteral)
        #expect(rejection("testuser 反馈说界面卡住了") == .forbiddenLiteral)
        #expect(rejection("built on test-macbook overnight") == .forbiddenLiteral)
    }

    // MARK: - Confusables

    @Test("fullwidth forms cannot walk past the ASCII structural rules")
    func fullwidthConfusablesRejected() {
        // The whitelist admits the fullwidth block for CJK punctuation like
        // （）， — and that same block carries fullwidth ASCII: `／` `．` `＄`
        // `｜` and the whole Latin alphabet. Every structural rule matched
        // ASCII, so each of these sailed through until the checks were run
        // against an NFKC-normalized copy.
        #expect(rejection("／Users／alice 下面的东西") == .disallowedCharacter)
        #expect(rejection("改了 测试．swift 的解析") == .dottedIdentifier)
        #expect(rejection("重写了 ｇｅｔＵｓｅｒ 的实现") == .codeIdentifier)
        #expect(rejection("连到 １０．０．０．１ 之后卡住") == .ipAddress)
        #expect(rejection("token ｇｈｐ＿AbCdEfGhIjKlMnOp") == .secretPrefix)
    }

    @Test("a CJK filename with an ASCII dot is rejected")
    func cjkFilenameRejected() {
        // `A-Za-z` on both sides of the dot misses this, and it is a filename
        // in exactly the kind of codebase this journal is written about.
        #expect(rejection("改了 测试.swift 里的解析") == .dottedIdentifier)
        #expect(rejection("看了 文档.md 之后重写") == .dottedIdentifier)
    }

    @Test("normalization judges but never rewrites")
    func normalizationDoesNotRewrite() {
        // A fullwidth string that is otherwise clean must come back verbatim —
        // the promise is "what came back is what the model wrote".
        let input = "今天推进了三个项目（都已交付），没有踩坑。"
        #expect(JournalSanitizer.sanitize(input, policy: policy) == input)
    }

    @Test("an item that only exceeds the budget after normalization is rejected")
    func normalizationExpansionCaught() {
        // NFKC can expand (㍿ → 株式会社). A short-looking item must not be
        // able to smuggle a long one past the budget.
        let tight = JournalSanitizer.Policy(maxScalars: 3)
        #expect(JournalSanitizer.sanitize("㍿株式", policy: tight) == nil)
    }

    // MARK: - Bypasses found by an adversarial probe that compiled and ran this file

    @Test("percent-encoding cannot smuggle a credential past every other rule")
    func percentEncodedSecretRejected() {
        // `%67%68%70%5F…` is `ghp_…` one character at a time: no known prefix
        // survives the encoding, every run is two characters long so nothing
        // looks opaque, and there is no dot or camel boundary anywhere.
        let encoded = "deploy token %67%68%70%5F%41%62%43%64%45%66%47%68"
        #expect(rejection(encoded) == .percentEncoded)
        // A bare percent sign is ordinary prose and must survive.
        #expect(rejection("提升了 30% 左右。") == nil)
        #expect(rejection("Cut it by 30% overall.") == nil)
    }

    @Test("IPv6 is rejected as well as IPv4")
    func ipv6Rejected() {
        // A v6 literal contains no dots at all, so every dot-based rule misses
        // it by construction.
        #expect(rejection("Connected to 2001:0db8:85a3:0000:8a2e:0370:7334") == .ipAddress)
        #expect(rejection("绑到 fe80::1 之后就好了") == .ipAddress)
        // Two false positives this rule is one careless regex away from.
        // NFKC folds the fullwidth colon — ordinary Chinese punctuation — into
        // `:`, so a colon-counting pattern would eat any two-clause sentence.
        #expect(rejection("结论：改了两处，跑了测试：都过了。") == nil)
        // And two colons are also just a time.
        #expect(rejection("会议 12:30:45 开始，没什么进展。") == nil)
    }

    @Test("acronym-prefixed type names are rejected, plural acronyms are not")
    func acronymIdentifiersRejected() {
        // `[a-z][A-Z]` alone misses the commonest naming style in this very
        // codebase — the boundary in APIClient is upper-to-upper.
        #expect(rejection("Rewrote APIClient after the outage.") == .codeIdentifier)
        #expect(rejection("换掉了 URLSession 的实现") == .codeIdentifier)
        #expect(rejection("Replaced JSONDecoder with something simpler.") == .codeIdentifier)
        // …but ordinary English plurals of acronyms must survive, or the
        // journal silently loses normal sentences.
        #expect(rejection("Unified a few APIs today.") == nil)
        #expect(rejection("Cleaned up the IDs we were passing around.") == nil)
    }

    @Test("a UUID is rejected even though hyphens split it into short pieces")
    func uuidRejected() {
        // Asserting the specific reason, not just "rejected". An earlier
        // version of this test used `!= nil` and was passing via the phone
        // rule, so the rule it was written for was never actually exercised.
        #expect(rejection("Reset token 550e8400-e29b-41d4-a716-446655440000") == .highEntropy)
        // Trailing punctuation must not hide it — splitting on whitespace let
        // a single full stop carry the whole UUID through.
        #expect(rejection("The token was 123e4567-e89b-12d3-a456-42f614a74abc.") == .highEntropy)
        // A date is hyphenated digits too and must survive.
        #expect(rejection("排期定在 2026-07-30 之前。") == nil)
        // So must a hyphenated release label — words, not hex.
        #expect(rejection("把 2026-07-30-release-candidate 部署到了测试环境。") == nil)
    }

    // MARK: - False positives the leak rules were one careless line from causing

    @Test("large numbers survive; only grouped phone shapes are rejected")
    func largeNumbersSurvive() {
        // A bare run of digits was the first phone rule, and it rejected
        // `Processed 1000000000 rows` — fatal for a journal whose subject is
        // token counts. A large number is not a leak.
        #expect(rejection("Processed 1000000000 rows without timing out.") == nil)
        #expect(rejection("压测跑完了 1000000000 条记录，没有超时。") == nil)
        #expect(rejection("Call 415 555 0123 for details.") == .phoneNumber)
        #expect(rejection("Call (415) 555-0123 for details.") == .phoneNumber)
    }

    @Test("standard English abbreviations survive the dotted rule")
    func abbreviationsSurvive() {
        // `e.g.` is single letters either side of the dot; a filename has a
        // real word. Requiring a two-letter run on one side separates them.
        #expect(rejection("Documented edge cases, e.g. empty responses.") == nil)
        #expect(rejection("Deferred the rest, i.e. the scheduler work.") == nil)
        #expect(rejection("改了 测试.swift 的解析") == .dottedIdentifier)
    }

    @Test("mixed-case product names survive the acronym rule")
    func productNamesSurvive() {
        // `OAuth` matches the acronym-identifier shape exactly. The whitelist
        // is the designed mechanism for this, not a narrower regex.
        #expect(rejection("Simplified the OAuth login flow after the outage.") == nil)
        #expect(rejection("接通了 OAuth 登录，顺便简化了回调流程。") == nil)
        #expect(rejection("Rewrote APIClient after the outage.") == .codeIdentifier)
    }

    @Test("IPv6 survives trailing punctuation and zone suffixes")
    func ipv6NotHiddenByPunctuation() {
        #expect(rejection("Connected to 2001:db8::1, then retried.") == .ipAddress)
        #expect(rejection("Connected to fe80::1%en0 and retried") == .ipAddress)
    }

    @Test("phone numbers are rejected; personal names are out of this layer's reach")
    func phoneNumbersRejected() {
        #expect(rejection("call 415-555-0123 for details") == .phoneNumber)
        // Deliberately NOT rejected: a bare run of digits. The rule matches the
        // grouped *shape* instead, because "any nine digits" ate `Processed
        // 1000000000 rows` — and a journal about token spend is made of large
        // numbers. An ungrouped digit run is a quantity, not a phone number.
        #expect(rejection("工号 123456789012 的那位") == nil)
        // Documented non-goal: a name is indistinguishable from any other two
        // capitalised words. The design puts customer identity behind the
        // project alias/exclusion table, not here — asserting it so the gap is
        // recorded rather than discovered later.
        #expect(rejection("Fixed the outage for Jane Smith today.") == nil)
    }

    @Test("policy terms are normalized into the same domain as the text")
    func policyTermsNormalized() {
        // Otherwise the normalization that closed the fullwidth bypass opens
        // two more: a fullwidth alias stops being recognised (silent false
        // positive), and a fullwidth identity literal stops matching (a leak).
        let custom = JournalSanitizer.Policy(
            maxScalars: 200,
            properNouns: ["ＡcmeWidget"],
            forbiddenLiterals: ["ａlice"]
        )
        #expect(JournalSanitizer.sanitize("推进了 AcmeWidget 的接入", policy: custom) != nil)
        #expect(JournalSanitizer.sanitize("alice 反馈了一个问题", policy: custom) == nil)
    }

    // MARK: - Length and emptiness

    @Test("over-length items are discarded, never truncated")
    func overLengthDiscarded() {
        // Truncation could leave half a secret, so there is no truncation path
        // to test — only rejection.
        let long = String(repeating: "工", count: 201)
        #expect(rejection(long) == .tooLong)
        #expect(rejection(String(repeating: "工", count: 200)) == nil)
    }

    @Test("length counts unicode scalars so CJK and Latin cost the same")
    func lengthCountsScalars() {
        let tight = JournalSanitizer.Policy(maxScalars: 5)
        #expect(JournalSanitizer.sanitize("工作日志记", policy: tight) != nil)   // 5
        #expect(JournalSanitizer.sanitize("工作日志记录", policy: tight) == nil)  // 6
        #expect(JournalSanitizer.sanitize("abcde", policy: tight) != nil)
        #expect(JournalSanitizer.sanitize("abcdef", policy: tight) == nil)
    }

    @Test("blank and whitespace-only items are rejected")
    func blankRejected() {
        #expect(rejection("") == .empty)
        #expect(rejection("   \n  ") == .empty)
    }

    @Test("accepted text is returned unchanged apart from trimming")
    func acceptedTextNotRewritten() {
        // Callers rely on "what came back is what the model wrote".
        let input = "  修复了压缩标记的计数问题。  "
        #expect(JournalSanitizer.sanitize(input, policy: policy) == "修复了压缩标记的计数问题。")
    }

    // MARK: - List filtering

    @Test("list filtering drops only the offending items and keeps order")
    func listFilteringKeepsOrder() {
        let items = [
            "补齐了实机验证。",
            "改了 Foo.swift 里的解析。",
            "关掉了里程碑。",
        ]
        #expect(JournalSanitizer.sanitize(items, policy: policy) == [
            "补齐了实机验证。", "关掉了里程碑。",
        ])
    }
}
