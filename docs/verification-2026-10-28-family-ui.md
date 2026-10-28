# Refresh shared native interface · October 28, 2026

## Implemented

A shared identity/status header, consistent flat rows and footer, clearer empty/failure states, and Reduced Motion-aware progress. Settings now opens in a native SwiftUI Settings window with the same store and login controller.

The four apps use an identical `FamilyHeader.swift` and the same
[family guide](brand/FAMILY.md). Existing Icon Composer artwork is retained.
No container app, web UI or new shared runtime was introduced.

## Verification

- Debug suite: **101 reported: 96 passed, 5 opt-in live installer tests skipped, zero failures**.
- Developer ID-signed arm64 Release build succeeded with Hardened Runtime and
  debug entitlement injection disabled.
- `xcodegen generate` and `git diff --check` passed. Generated projects include
  the new views and build number.
- Reviewed the real panel in dark appearance and the native Settings form in light appearance using an isolated Debug fixture harness. The Settings button and Command-comma both opened Refresh Settings; Command-W returned to the panel. The temporary harness is excluded from shipping source and ran no inventory, background scheduler or installers. Final source was rebuilt and the complete test suite rerun after the harness was removed.
- Signed **0.1.5 (8)** installed at `/Applications/UpdateBar.app`; strict deep
  signature verification passed, the signing requirement matched the prior app,
  and the installed process finished launching with display name **Refresh**.
- Bundle ID `com.erole.UpdateBar`, executable/app filename, data and preference paths,
  updater identity/feed and icon resources are unchanged.

Test/build logs and renders are ignored under `build/family-ui/`:
`debug-final.log` and `signed-release.log`. Test results were checked directly;
render success alone does not establish native interactions.

Typical commands (the widget suite also uses a pre-created preview output folder):

```sh
xcodegen generate
xcodebuild -project UpdateBar.xcodeproj -scheme UpdateBar -configuration Debug -destination 'platform=macOS' -derivedDataPath build/family-ui/DerivedData CODE_SIGNING_ALLOWED=NO test
xcodebuild -project UpdateBar.xcodeproj -scheme UpdateBar -configuration Release -destination 'generic/platform=macOS' -derivedDataPath build/family-ui/DerivedData CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY='Developer ID Application' DEVELOPMENT_TEAM=T26T3G8C7Q ENABLE_HARDENED_RUNTIME=YES CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO ARCHS=arm64 build
```

## Local installation and boundaries

Installation staged and verified each app, requested a normal quit, waited for
exit, preserved the prior bundle and swapped the verified copy into the same
path. No force-quit or data migration was used. Rollback bundles and per-app
installation manifests remain outside Git in
`~/Code Support/backups/mac-utility-family/2026-10-28-family-ui-144658/` and
`2026-10-28-family-ui-final/`. Manifests record the final source commit and installed
code hash after source handoff.

These are local trial builds. No Apple notarization upload, GitHub binary release
or public deployment was run. Full light/dark, Increase Contrast and VoiceOver
coverage is not claimed. Physical typing, TV control, Login Items changes,
real installers and automatic update/relaunch acceptance were not exercised by
this interface pass. Earlier release/runtime evidence applies to its recorded builds.
