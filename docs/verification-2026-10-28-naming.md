# Refresh display-name adoption · October 28, 2026

## Change

UpdateBar now presents itself as **Refresh** in bundle metadata and user-facing copy.
The four apps adopt the same [family guide](brand/FAMILY.md): individual names,
simple dimensional object icons and native Mac controls, typography and spacing.
The existing layered Icon Composer artwork is retained.

Repository and checkout names, Xcode target/module, executable and app filenames,
bundle IDs, storage, preferences and update feeds remain stable. No app version
or build number changed. The README now records the current pinned AppUpdater
revision where the older text was stale.

## Verified

- `xcodegen generate` completed; the generated project had no changes.
- Debug suite succeeded: **101 tests reported, 5 skipped, zero failures**.
- Release build succeeded with `CODE_SIGNING_ALLOWED=NO`.
- Built Debug and Release Info.plists contain `CFBundleDisplayName = Refresh` and
  `CFBundleName = Refresh`, while preserving `com.erole.UpdateBar`, executable
  `UpdateBar` and icon resource name `UpdateBar`.
- Compared source Info.plist against the prior commit: only display/name keys
  changed. Project configuration, updater feed/ZIP configuration and icon artwork
  are unchanged. Shared guide contents match across all four repositories.
- Checked changed documentation links and `git diff --check`.
- Added and passed a regression test covering all four new display names against their existing GitHub source and fallback release repositories. The five skipped cases require opt-in live installer authorization.
- Xcode emitted its expected App Intents metadata-extraction warning because this app has no AppIntents framework dependency; no compiler errors occurred.

Commands:

```sh
xcodebuild -project UpdateBar.xcodeproj -scheme UpdateBar -configuration Debug -destination 'platform=macOS' -derivedDataPath build/naming-verification/DerivedData -resultBundlePath build/naming-verification/Debug-verified.xcresult CODE_SIGNING_ALLOWED=NO test
xcodebuild -project UpdateBar.xcodeproj -scheme UpdateBar -configuration Release -destination 'platform=macOS' -derivedDataPath build/naming-verification/DerivedData CODE_SIGNING_ALLOWED=NO build
```

Ignored local logs: `build/naming-verification/debug-test.log` and
`build/naming-verification/release-build.log`. Initial sandboxed attempts could
not access Xcode caches/package downloads; the normal-access reruns above passed.

## Boundaries

No local app installation, notarization, binary release or deployment was run.
These unsigned build checks do not establish installed-name presentation,
Login Items/permission display, updater/relaunch migration, or a native UI review.
The renamed Release app has not been launched against the user's real data.
Historical release/runtime evidence in earlier reports applies to those older builds.
