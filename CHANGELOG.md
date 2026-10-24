# Changelog

Release versions describe the app. Settings schema versions are tracked separately.

## [Unreleased]

- Choose an open-source license before publishing the source as open source.
- Sign and notarize public downloads when a Developer ID is available.
- Validate the app on the oldest supported macOS release.

## [0.1.0] — 2026-10-24

Initial local distribution candidate; not yet published as a public release.

### Reading and translation

- Native PDF tabs with a persistent filename bar and optional separate windows.
- A centered welcome window and first document window, with stable positioning when adding tabs.
- Selection-based English-to-Chinese translation in a resizable sidebar.
- Baidu Translate and configurable Chat Completions-compatible model endpoints.
- Editable zoom, page navigation, and saved reading positions.

### Annotations

- Highlights and underlines with a shared three-color palette.
- Red typewriter notes with adjustable size and Hannotate where available.
- Re-editing, moving, deleting, undoing, and redoing annotations.
- Standard PDF saving and Save As.

### Distribution and upgrades

- Standalone Apple silicon release app and macOS DMG packaging.
- Installed user data stored independently of the source checkout and app bundle.
- Versioned settings, legacy-format loading, and backup before configuration replacement.
- Release/build version management and documented manual upgrades.
