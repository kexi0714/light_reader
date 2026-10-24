# Releasing and upgrades

This document is the compatibility contract for future Light Reader releases.

## Stable identity and user data

Preserve these values unless an explicit, tested migration is included:

| Item | Current value | Reason |
| --- | --- | --- |
| Bundle identifier | `local.lightreader.mac` | macOS document association and app identity |
| Installed data directory | `~/Library/Application Support/Light Reader/` | Credentials, settings, and reading positions survive app replacement |
| Development data directory | `<checkout>/.local/` | Keeps the current developer's setup separate from distributed builds |
| Annotation format | Standard PDF annotations saved in the PDF | User notes survive upgrades and do not depend on an app database |

The bundle identifier is provisional in name but already used by local builds. If it is changed before the first public release, record the change and test document associations and data access. Do not generate a new identifier for every version.

Release apps must never include `LightReaderProjectRoot` in their Info.plist. That key is reserved for development/QA builds. Never write user data inside the app bundle, disk image, working directory, or `/Applications`.

Debug and release builds use the same main bundle identifier; avoid running both against the same documents during testing. The separate QA build has its own identifier and data directory.

## Version policy

`Resources/Info.plist` is the single source of truth:

- `CFBundleShortVersionString`: `major.minor.patch`, for example `0.1.0`.
- `CFBundleVersion`: a positive integer that increases for every distributed build, even if the marketing version is unchanged.

To prepare the next release:

```sh
./scripts/set-version.sh 0.1.1 2
```

The helper rejects a non-increasing build number. Update CHANGELOG.md with the actual changes before publishing. Do not increment the settings schema just because the application version changes.

## Settings migration rules

`SettingsFile.swift` reads a flat JSON object with a `schemaVersion` field.

- **Schema 0:** original JSON with no schema field. Read it without changing the file.
- **Schema 1:** the same fields plus `schemaVersion: 1`. Written when the user saves settings.
- Missing optional configuration fields receive defaults. Existing provider values and credentials must remain intact.
- A malformed configuration or a schema newer than the app supports must produce an error and must not be overwritten. Settings actions remain unavailable after an initial load error until the data is repaired or a compatible app is installed and restarted.
- Before replacing an existing supported settings file, retain its bytes as `settings.previous.json`. This is one previous configuration, not a complete history or a backup of credentials.

For any future incompatible schema:

1. Add an explicit migration from each supported previous schema. Keep it independent of UI code.
2. Migrate in memory, validate the result, back up the original, and atomically write the new file. Never edit the only copy in place.
3. Test real legacy fixtures, missing fields, corrupt files, unknown future versions, and repeated migration.
4. Document rollback limitations. An older app may not understand new fields or schemas. Do not claim arbitrary downgrades are safe.
5. Keep secrets out of logs and test fixtures. If credential or reading-history formats change, give them their own version/migration handling before shipping that change.

The initial developer-to-installed-app move is intentionally manual. Do not bake a developer's absolute path or credentials into a general-purpose installer. Quit both apps and copy the local files privately, or configure the installed app once.

## Build and validate

```sh
./scripts/check.sh
./scripts/build.sh debug
./scripts/package.sh
./scripts/verify-release.sh
```

The package script targets Apple silicon (`arm64`) by default, then creates a compressed DMG with an Applications shortcut and a SHA-256 checksum. The optional `universal` argument compiles and combines both architectures for future use; it is not the current release target. Only app resources and installation instructions enter the image. Packaging invokes `verify-release.sh` to check architecture, signature, absence of the development path, and an explicit file allowlist. Update that allowlist deliberately if a later release introduces a framework or additional resources.

Before release, check:

- The `arm64` architecture, minimum macOS version, bundle ID, version, and signature.
- No project-root Info.plist key, credentials, `.local` folders, personal PDFs, or debugging files inside the app or image.
- Launch from a location outside the checkout with no Python/Conda dependency.
- First launch, provider configuration persistence, tabs, PDF save, and closing unsaved documents.
- Upgrade from the preceding version with existing credentials, reading positions, and edited PDFs.
- Physical Apple silicon Macs and the oldest supported macOS version. If Intel support is added later, validate it on physical Intel hardware; cross-compilation alone is not runtime validation.

## Signing and notarization

By default builds are ad-hoc signed. That is suitable for local development, but it is not a Developer ID signature and does not establish a verified publisher for downloads.

If a Developer ID Application certificate is installed, build with its exact name:

```sh
SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' ./scripts/package.sh
```

This signs the app with Hardened Runtime and a secure timestamp. Certificate names and team IDs must be supplied by the publisher; the scripts do not invent or provision them.

For public releases, submit the final disk image using Apple's `notarytool` with a locally configured credentials profile. After acceptance, staple the ticket to the DMG, validate it, and recompute the checksum, since stapling changes the image bytes. Never put Apple credentials or signing private keys in the repository or in distributable archives.

Packaging, notarization, uploading to GitHub Releases, and publishing source are separate actions. The local scripts do not publish anything automatically.

## Manual upgrade procedure

For users:

1. Save open PDFs and quit Light Reader.
2. Open the newer DMG and replace Light Reader in Applications.
3. Launch the new app. It reads the same Application Support folder.

Do not uninstall by deleting Application Support during an upgrade. Replacing the application bundle does not remove PDF annotations or the external data folder.

## Future automatic updates

No updater is included yet. Keep manual replacement working even if an updater is added later.

Before adding an updater, choose a maintained update framework and a stable HTTPS release/feed location. Separate update-signing keys from translation API keys, preserve monotonic build numbers, verify downloaded updates, and provide a user-controlled update flow. Test interrupted updates, invalid signatures, incompatible macOS versions, and migration failures. Adding an updater must not require moving or deleting existing user data.

## Source publication

Before the first public source release, choose and add a license, review the tracked-file list, and ensure private local data is excluded. `.gitignore` helps with new files but does not remove secrets already committed. Do not upload build or diagnostic directories as source.
