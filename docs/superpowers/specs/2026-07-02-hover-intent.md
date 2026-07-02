# Hover Intent for Notch Expansion

## Problem

The compact notch expands as soon as the cursor enters its activation area. In
a vertically arranged multi-display setup, crossing from the MacBook display to
the display above passes through that area and opens ZackEyes unintentionally.

## Scope

- Delay hover expansion until the pointer has remained within the activation
  area for 250 milliseconds.
- Cancel the pending expansion when the pointer leaves the activation area.
- Use the same behavior for physical and simulated notch controllers.
- Preserve forced expansion, visibility rules, sticky permission behavior,
  outside-click dismissal, and the existing collapse grace period.
- Preserve the physical notch panel's compact-state mouse pass-through.

Click-to-expand for the simulated notch remains unchanged. Adding click capture
to the physical notch is out of scope because its compact panel intentionally
ignores mouse events so menu-bar clicks pass through.

## Design

Introduce a small `HoverIntentTracker` value type in AppLib. It owns a
generation counter and returns a token when hover begins or movement exceeds an
8-point tolerance. Controllers schedule a main-queue work item for 250
milliseconds for each new token. On firing, the token must still be current and
the controller must re-check current geometry and visibility before expanding.

Leaving the activation area, changing panel state, changing screens, hiding the
panel, or tearing down the controller invalidates the token and cancels the
pending work item. Repeated local/global mouse events within the movement
tolerance do not restart the dwell timer; continued movement does.

## Acceptance Criteria

- A cursor that enters and exits within 250 milliseconds does not expand.
- A cursor that stays inside for 250 milliseconds expands.
- A stale delayed callback cannot expand after cancellation.
- Forced expansion remains immediate.
- Physical and simulated notch modes use the same dwell duration.
- Existing build and test suites pass.
