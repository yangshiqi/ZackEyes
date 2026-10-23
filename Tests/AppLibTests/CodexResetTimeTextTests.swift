import Foundation
import Testing
@testable import AppLib

struct CodexResetTimeTextTests {
    @Test func rendersLocalClockAndOffsetForEachTimestamp() throws {
        let instant = try #require(ISO8601DateFormatter().date(from: "2026-10-23T11:50:00Z"))
        let shanghai = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let locale = Locale(identifier: "en_GB")

        #expect(CodexResetTimeText.local(instant, timeZone: shanghai, locale: locale).contains("19:50 UTC+8"))
        #expect(CodexResetTimeText.local(instant, timeZone: losAngeles, locale: locale).contains("4:50 UTC-7"))
    }

    @Test func offsetUsesTheDateAndSupportsFractionalHours() throws {
        let winter = try #require(ISO8601DateFormatter().date(from: "2026-01-15T12:00:00Z"))
        let summer = try #require(ISO8601DateFormatter().date(from: "2026-07-15T12:00:00Z"))
        let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let kolkata = try #require(TimeZone(identifier: "Asia/Kolkata"))
        let locale = Locale(identifier: "en_GB")

        #expect(CodexResetTimeText.local(winter, timeZone: losAngeles, locale: locale).contains("4:00 UTC-8"))
        #expect(CodexResetTimeText.local(summer, timeZone: losAngeles, locale: locale).contains("5:00 UTC-7"))
        #expect(CodexResetTimeText.local(winter, timeZone: kolkata, locale: locale).contains("17:30 UTC+5:30"))
    }
}
