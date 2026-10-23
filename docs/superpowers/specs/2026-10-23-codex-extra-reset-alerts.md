# Codex extra reset announcements

## Goal

Show a timely, source-linked notice when a public announcement describes an extra Codex usage reset or banked reset. This is separate from the account-specific 5h/7d `resets_at` readings. An announcement never proves that a particular account has received a reset.

## Source and trust

Use the public, documented `https://codexreset.ai/api/v1/resets.json` endpoint. Its schema version 1 carries `scheduled` (when an official post predicts a future reset) and `events` (recorded reset and banked-reset announcements). The provider permits unauthenticated use with attribution, client caching and polling no more than once per minute. Poll every five minutes while a local Codex session is active. Do not transmit session data, authentication, prompts or configuration. Ignore malformed, stale, unsupported or unlinked records. Show the original announcement link and name the aggregator.

## Presentation

Show one current announcement in the shared expanded session area, including type, phase, scope, announcement time, and local expected time when exact. A calendar-day-only schedule is displayed as a day, never an invented instant. The notice is a link to the original post and explicitly states that account delivery must be checked in Codex `/usage`. Thus it appears in both physical and simulated notch and the menu fallback without changing quota bars. Do not show it during demo. A completed event is labeled as a reported completion, not account confirmation.

System notifications are optional and independently controlled. Notify only for a current announcement while a local Codex session is active. Deduplicate by stable source URL plus phase across polls and restarts; a completion update can notify after a preview. On first poll, an announcement or reported completion from the last six hours may notify; older events, stale feeds, or only Claude/remote/demo sessions do not notify. An announcement without a scheduled time must say that the exact reset time is unknown. Config switches control feed fetching and notifications; both are enabled by default so active Codex users receive reminders. Disabling the feed clears the visible notice and stops requests.

## Failure behavior

Network errors preserve an existing notice only until its short freshness limit, then remove it. Invalid schema or unsupported source URLs are ignored. Use a finite response size and request timeout. No bridge, hook installer, session record or account quota state is modified.

## Verification

Test parsing and selection with fixture JSON covering scheduled exact/day-only, banked, completion, stale/invalid/conflicting records. Test notification gating and persistence, config round trips, and shared presentation. Run relevant tests, full Swift build/test and app assembly.
