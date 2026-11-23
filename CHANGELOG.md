# Changelog

Release versions describe the app. Settings schema versions are tracked separately.

## [0.1.1] — 2026-11-23

- Scroll while dragging to extend a text selection across pages.
- Add compact 10 pt notes that grow to the right, stay anchored during scrolling, and support moving, resizing, and font-size changes.
- Fit highlights to individual lines and recolor existing highlights or underlines from the toolbar.
- Update the app icon and add bilingual download and installation guides.

- Refresh the translation header with a soft sage background, dark green lettering, and a subtle language badge.

- Hold Command while dragging to append disjoint PDF passages and translate the combined selection in document order without duplicated overlaps.

- Default new documents to 220% zoom while preserving saved reading zoom; move translation actions into the sidebar toolbar, reduce top padding, and label the section “翻译：”.

- Use regular Songti for the translation sidebar text, with bold Songti section headings.

- Rename the app to LiRe, from “light reading”, including menus, welcome screen, app bundles, and future DMG filenames; preserve the existing app identity and data directory for upgrade compatibility.

- Allow one continuous selection across translated text, section headings, and the editable original text.

- Default sidebar text zoom to 170%, scale the bold section headings with the text, and use regular weight for both text bodies.

- Move translation configuration into the sidebar, remember its independent font zoom, and expand original/translated text selection into surrounding blank space.

- Allow editing the original text and retranslating it from its context menu; refresh and retry use the edited text too.

- Strengthen the translation sidebar header and show translated text before the original with bold section titles.

- Remove fixed PDF outer margins and shadows; retain a gray canvas that is covered naturally as the page is zoomed in.
- Distribute filename tabs evenly across the full reading-pane width.

- Place filename tabs above the reading pane and align the translation sidebar with the tab row.
- Use a native draggable divider and preserve its width across document tabs and sidebar toggles.

## [0.1.0] — 2026-10-24

First distribution, tagged `0.1` on GitHub.

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
