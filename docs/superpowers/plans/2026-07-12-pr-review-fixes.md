# PR Review Fixes Implementation Plan

1. Restore a persistent simulated-notch full subtree and gate hidden timer/animation activity.
2. Route theme, notification sound, and hotkey saves through ConfigStore's defensive update helper; add corrupt-file tests.
3. Centralize `SessionInfo.needsAttention` and `urgencyRank`; update grouping, compact presentation, sorting, and tests.
4. Add Settings notification tests, lazy view-model creation, display refresh, and a persistent Quit action.
5. Add endpoint tests, named state colors/thresholds, non-color menu-bar pressure symbols, reduced-motion static cues, and cleanup.
6. Run focused tests, full build/test, app assembly, and diff review.
