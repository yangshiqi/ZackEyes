# Implementation plan

1. Add fixture-driven tests for schema parsing, announcement selection, time handling, source URL validation and notification gates. Observe expected failure.
2. Implement the decoder and policy as a small usage-domain unit. Keep it independent from existing quota snapshots.
3. Add a foreground service with bounded, low-frequency URLSession polling while local Codex is active. Persist notification identities and expose one current notice.
4. Add config controls, notification delivery and tap-through, then a shared announcement view in the expanded session area.
5. Verify tests/build/app assembly, review diff and commit the atomic feature.
