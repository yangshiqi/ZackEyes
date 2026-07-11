# Unified Settings Window Design

## Goal

Replace the two growing settings menus with one non-modal macOS settings window. The simulated-notch gear, physical-notch gear, and status-bar context menu all open the same window and expose the same preferences.

## Scope

- General preferences: island visibility, compact agent, Today usage, global hotkey, simulated-notch position.
- Appearance: buddy theme and notification sound with preview.
- Notifications: notify when an agent waits for input.
- Integrations: hook health, repair, diagnostics export, uninstall integrations.
- About: version and update actions.
- Keep `~/.zackeyes/config.json` compatible and preserve all existing runtime notifications.

Bridge, socket protocol, and session state behavior are out of scope.

## Window Behavior

- One reusable `SettingsWindowController` instance owned by `AppDelegate`.
- Standard titled, closable, resizable `KeyablePanel` at floating level. `LSUIElement` apps cannot reliably raise a normal window above the current app; the nonactivating panel remains keyable without changing the notch panel's behavior.
- Non-modal: never call `runModal()`, so permission sockets continue to be serviced.
- Default size 720x520, minimum size 660x460, centered on first open.
- Repeated opens focus the existing window instead of stacking windows.
- Changes save immediately; there is no Save/Cancel footer.

## Information Architecture

The root view uses a 176pt sidebar with five sections: General, Appearance, Notifications, Integrations, About. The detail pane is an unframed form with compact section dividers. Controls follow macOS conventions: segmented pickers for small enums, toggles for booleans, menus for option sets, and icon buttons for preview/reset actions.

## State and Data Flow

`SettingsViewModel` loads from `ConfigStore` when created and owns the editable values. Each mutation:

1. saves through the existing defensive `ConfigStore` API;
2. updates its published value;
3. posts the existing notification used by controllers where applicable.

This keeps the persisted JSON shape unchanged while removing setting actions from `GearMenuTarget` and `StatusBarMenu`.

## Entry Points

- Both notch gear buttons invoke `SettingsWindowController.show()` directly.
- The status-bar context menu becomes: Settings..., About ZackEyes, separator, Quit ZackEyes.
- Update availability remains visible inside the About page.

## Safety

- The settings window may become key; `NotchPanel` and `SimulatedNotchPanel` invariants are unchanged.
- Hook health is read-only. Repair and uninstall continue using existing guarded implementations.
- Diagnostics continue using the existing redacted report window.
- Corrupt config files remain untouched by defensive save methods.

## Verification

- Unit-test view-model mutations with an isolated `ConfigStore` directory.
- Build all targets and run the full Swift test suite.
- Assemble the app bundle and manually verify all three entry points, singleton window behavior, immediate persistence, and permission prompts while Settings is open.
