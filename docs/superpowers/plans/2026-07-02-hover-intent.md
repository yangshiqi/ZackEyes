# Hover Intent Implementation Plan

1. Add a testable `HoverIntentTracker` to AppLib.
2. Add unit coverage for begin, duplicate enter, cancellation, and stale token
   rejection.
3. Integrate a single pending expansion task into `NotchWindowController`.
4. Integrate the same behavior into `SimulatedNotchController`.
5. Run `swift build`, `swift test`, and `make app`.
6. Commit as an atomic `fix(notch)` change.
