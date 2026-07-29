# Adaptive Notch Quota Layout Implementation Plan

1. Add a pure quota-window presentation model and its four-state test matrix.
2. Add centered physical-notch geometry and asymmetric-width tests.
3. Refactor the physical compact view to use the centered layout and data-driven compact slots.
4. Refactor physical and simulated expanded usage headers to render only available windows while keeping gear access and limit/empty states.
5. Run focused tests, full build/test, app assembly, and inspect the final diff.
