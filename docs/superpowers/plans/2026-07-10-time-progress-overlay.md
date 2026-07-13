# Time Progress Overlay Implementation Plan

1. Add `TimeProgressMode` and defensive `ConfigStore` persistence with default `.off`.
2. Add pure elapsed-window math and a reusable `UsageProgressTrack` renderer.
3. Replace the three duplicated quota-track implementations with the shared renderer.
4. Add the segmented setting and wire live updates through `UsageTracker`.
5. Add focused tests, update architecture docs, build/test/assemble, and visually verify Icon and Overlap.
6. Refine Overlap stacking from the live elapsed/usage comparison and pin the original theme sound mappings with regression coverage.

Bridge, session state, rate-limit ingestion, and context bars remain unchanged.
