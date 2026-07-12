# Unified Settings Window Design

## Goal

Replace the two growing settings menus with one non-modal macOS settings window. The simulated-notch gear, physical-notch gear, and status-bar icon share one small application command menu; its Settings command opens the same window and preferences.

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
- Create its `SettingsViewModel` lazily on first show so an unopened window does not read configuration or hook health at launch.
- Standard titled, closable, resizable `KeyablePanel`. It uses floating level while key for reliable `LSUIElement` presentation, then drops to normal level after focus leaves so it does not cover the user's editor or terminal.
- Non-modal: never call `runModal()`, so permission sockets continue to be serviced.
- Default size 720x520, minimum size 660x460, centered on first open.
- Repeated opens focus the existing window instead of stacking windows.
- A persistent sidebar footer exposes Quit because this LSUIElement app has no Dock or main application menu.
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

- Both notch gear buttons pop the exact `StatusBarMenu` used by the status-bar icon's right click.
- The shared menu is: Settings..., About ZackEyes, separator, Quit ZackEyes.
- When an update is available, the shared menu prepends the same Update command and the gear retains its red badge.

## Safety

- The settings window may become key; `NotchPanel` and `SimulatedNotchPanel` invariants are unchanged.
- Hook health is read-only. Repair and uninstall continue using existing guarded implementations.
- Diagnostics continue using the existing redacted report window.
- Corrupt config files remain untouched by defensive save methods.

## Verification

- Unit-test view-model mutations with an isolated `ConfigStore` directory.
- Build all targets and run the full Swift test suite.
- Assemble the app bundle and manually verify all three entry points, singleton window behavior, immediate persistence, and permission prompts while Settings is open.
