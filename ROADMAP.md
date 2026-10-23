# UpdateBar roadmap

Current focus: installer lifecycle and clear completion states. The 2026-10-23
pass separates package handoff from completed updates, excludes interactive packages
from Update all, preserves recent staged packages, guards normal Quit during updates,
and adds accessible release-note controls and refresh shortcut.

Earlier reliability and repeat-check performance work: The 2026-10-12 audit
implemented shared refresh work, exclusive installers, decoded index caching,
platform-aware Homebrew results, installed-artifact ownership, Sparkle compatibility
filters, HTTPS redirect protection, and accurate incomplete-check status.

Next verification work:

- Verify Homebrew password-required failures on a real affected cask. Normal quit,
  fresh download, automatic relaunch, and refresh are now verified below.
- Verify the menu visually on macOS 27 and newer, plus native/Rosetta and Intel
  Homebrew setups. Secondary Homebrew prefixes are deliberately excluded.
- Profile a larger app library with Instruments; current benchmark isolates
  index loading and does not measure total network-check latency.
- Continue validating real installer flows on supported macOS configurations.

See `docs/audit-2026-10-12.md` for observed verification and remaining boundaries.

Verification on 2026-10-23: the Xcode test suite passed (97 executed, four opt-in
live-install tests skipped, zero failures). The local build/launch check passed,
and a read-only live report completed without source failures. Xcode emitted only
its App Intents metadata-extraction warning (this app has no App Intents dependency).
The authorized macOS accessibility/screenshot fallback subsequently verified the
menu, settings, scrolling, package details, and Command-R refresh on macOS 27.0.1.
Other supported macOS configurations and installer paths remain open.

Release verification found and fixed a macOS 27 startup exception: the background
scheduler rejected tolerance equal to its interval. Build 3 uses half the interval
and adds a real-system scheduler test. Four opt-in installer tests remain skipped.

UpdateBar 0.1.1 (3) was Developer ID signed, notarized, stapled, and installed in
`/Applications/UpdateBar.app` on 2026-10-23. Gatekeeper accepted it as Notarized
Developer ID. The installed app automatically scanned 103 apps and displayed 11
updates, with no uncaught startup exception. The pre-upgrade 0.1.0 copy is retained
outside the repository for rollback. The signed ZIP, checksum, and release notes were published as
[v0.1.1](https://github.com/erikrole/UpdateBar/releases/tag/v0.1.1), tagged at
`eec5fb77b98a1a72d62442a51a26e1b7299c2df3`.

Real Sparkle update verified on 2026-10-23 using the installed 0.1.1 (3):
CodexBar 0.79.0 → 0.80.0 was initiated with its Update button. Sparkle extracted
the downloaded ZIP and confirmed its EdDSA signature. The installed app passed
strict deep code-signature verification and Gatekeeper with its original developer
team preserved. The previously running process exited and the updated app relaunched.
UpdateBar automatically showed “Updated 1 app,” removed CodexBar from the pending
list, and reduced the count by one; an independent read-only report agreed.
Sparkle logged a stale download-bookmark warning but continued successfully.
Intermediate download-percentage UI was not captured. Private evidence and the
pre-update backup are retained outside the repository. Homebrew, DMG, interactive
package completion, and failure/recovery paths were not exercised in this test.

Homebrew app test on 2026-10-23 (installed UpdateBar 0.1.1 build 3): Granola's
Update button spawned `brew upgrade --cask granola` as a child of UpdateBar.
The app advanced from 7.663.2 to 7.668.2; Homebrew's installed cask receipt also
advanced to 7.668.2. The cached 293 MB DMG matched the cask SHA-256, and the
installed bundle passed strict deep signing verification and Gatekeeper.
The UI showed Downloading and automatically removed Granola, reducing pending
updates from 10 to 9. A read-only report agreed, although unrelated GitHub source
checks returned HTTP 403, so that report was incomplete overall.

This is a partial end-to-end pass: the archive was already cached, so fresh network
download was not verified. The old process remained running after Homebrew finished.
Granola's own Squirrel updater subsequently replaced/relaunched the app (confirmed
in its ShipIt log), before the manual restart attempt. That relaunch cannot be
credited to UpdateBar, whose Homebrew action has no explicit relaunch lifecycle.
Granola 7.668.2 is running with its window accessible. The backup and private test
evidence remain outside the repository. No implementation changes were made for
this test; a controlled Homebrew relaunch test remains required after the fix.

Homebrew relaunch fix and controlled live verification on 2026-10-23:
`BrewAppInstaller` now fetches before quitting, waits up to 30 seconds for a normal
exit, upgrades, and awaits relaunch before releasing the reservation and refreshing.
It leaves initially closed apps closed and attempts to reopen the previous app on
upgrade failure. Both UI and CLI use the same lifecycle. Regression scenarios cover
download failure, refusal to quit, upgrade failure, relaunch failure, and running
versus closed apps.

A controlled live test restored the retained CodexBar 0.79.0 bundle (preserving
settings and backing up 0.80.0), selected the actual Homebrew checker result, and
called the production action/store pipeline. Homebrew fetched the 81 MB archive
into a previously empty cache, upgraded its receipt to 0.80.0, and UpdateBar
relaunched CodexBar with a new PID. Automatic refresh removed the pending row and
showed “Updated 1 app.” Signing and Gatekeeper passed. This was an opt-in integration
harness, not a UI click: normal source precedence chooses Sparkle for CodexBar.
The earlier Cursor UI attempt used the direct-archive path because its old Caskroom
copy was detached; it updated/relaunched successfully but is not Homebrew proof.
The isolated full suite passed 99 tests with five opt-in live tests skipped; the
Homebrew live test separately passed. Concurrent app-self-update edits were excluded
from the isolated build. The published 0.1.1 release has not been replaced.

UpdateBar 0.1.2 (4) was Developer ID signed, notarized, stapled, installed, and
published on 2026-10-23 at https://github.com/erikrole/UpdateBar/releases/tag/v0.1.2.
The release targets `a1d588f1d57281eb403b3266d9a068700abd5cd6`; the uploaded ZIP
matches the local SHA-256 `0b0d31eb517be28d8830b35115c9231b56e1163f34b9ca5c9aa229c53efdca8e`.
The installed app passed strict code-signature verification and Gatekeeper,
launched from /Applications, and displayed its menu and automatic scan results.
The release report scanned 103 apps, with GitHub checks returning HTTP 403 because
the anonymous API quota was exhausted (remaining=0). This external check limitation
is separate from successful signing, installation, and GitHub release publication.
The previous installed app and release evidence are retained outside the repository.

- October 23: AppUpdater ZIP integration is prepared against package `5b5a941`, retaining macOS 27 and existing save/busy/quit safeguards. A new host release is still required; see README App updates.
