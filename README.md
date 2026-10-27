# UpdateBar

UpdateBar is a native macOS menu bar utility that tells you which of your apps
have updates and gets you to them in one click. It is a from-scratch take on
the idea behind [Latest](https://github.com/mangerlahn/Latest); no Latest code
is used.

- Lives in the menu bar with a count of pending updates and rechecks in the
  background (every 6 hours by default; 1, 3, 12, and 24 hours are the other
  choices), with a notification when something new appears. It can launch at login.
- Checks four sources: the Mac App Store, each app's own Sparkle feed, Homebrew
  casks, and GitHub Releases. Apps with a `com.erole.` bundle ID are linked to
  `erikrole/<name>` automatically.
- Shows each app once. An app's own updater decides: when the App Store or its
  Sparkle feed says it is current, a Homebrew or GitHub hint can't override that.
  The full order is in [source precedence](design-plans/source-precedence.md).
- Compares against the version actually on disk, so apps that updated themselves
  aren't flagged the way `brew outdated --greedy` flags them.
- Shows release notes inline, and lets you skip a version or ignore an app.
- Lists outdated Homebrew command-line tools (formulae) in their own section,
  matching `brew outdated`, with per-tool Upgrade and an Upgrade all that covers
  dependencies too. Pinned formulae and HEAD builds are left alone, and rebuilds
  of the same release are labelled as such. Homebrew's indexes are revalidated by
  ETag, so results are fresh within minutes of Homebrew publishing.
- Per-app beta opt-in for Sparkle apps whose feeds publish pre-release channels
  (Settings → Beta updates); beta offers are labelled in the list.
- One-click updates: `brew upgrade --cask` for Homebrew installs (as you, never
  with admin rights). Homebrew app updates download first, wait for a normal quit,
  and automatically reopen apps that were running. Unsaved work is never force-quit.
  Other supported paths include in-place installs for Sparkle apps that sign their updates
  (via the embedded [Sparkle](https://sparkle-project.org) framework, verified
  against each app's own EdDSA key; the app quits and reopens if it was running),
  and the App Store's Updates page for store apps. "Update all" runs every
  in-place update one after another, including my own apps' signed DMG or ZIP releases. Chrome, Edge, Brave, and Vivaldi open their
  own update page; other self-updating apps are launched.
- Signed package updates show “Install…” and open Apple’s Installer after verification.
  Finish there, then check again. These interactive packages are excluded from Update all.
- Release notes and options have an explicit keyboard-accessible button. Command-R
  checks again, and failure details can be selected and copied. Normal Quit waits
  until an active update finishes.

A failed update stays on that row and does not cancel the rest of Update all.
A Homebrew run that stops midway keeps what it already upgraded and says how
many were left. If brew needs a password, the message includes the Terminal
command to run. A source that could not be checked is listed as a failure, and
UpdateBar does not call that a clean bill of health.

Out of scope on purpose: a root install helper and Apple's private App Store
frameworks. Feeds that only work over plain HTTP are reported, not trusted.

## Build and run

Requirements: macOS 27 or later, Xcode 27 or later, and XcodeGen.

```sh
xcodegen generate
./script/build_and_run.sh --verify
```

The Codex Run action uses the same script. It quits the running UpdateBar, builds
into `build/dd`, and launches that local build. Run it when no app/tool installation
is active. Optional `--debug`, `--logs`, and `--telemetry` modes support diagnosis.
It does not replace your installed copy or produce a notarized release.

`UpdateBar --report` runs one check, prints what it found and exits without
notifications or changes to notification history:

```sh
UpdateBar.app/Contents/MacOS/UpdateBar --report
UpdateBar.app/Contents/MacOS/UpdateBar --install <bundle ID>   # supported installer; status 1 on failure
```

For packages, the CLI reports `OPENED` rather than `INSTALLED`; exit status 0
means the handoff to Installer succeeded. Recent packages survive app relaunches.
Startup cleanup removes packages older than seven days only when Installer is closed.

Homebrew's cask (~20 MB) and formula (~30 MB) indexes are cached in
`~/Library/Application Support/UpdateBar/` and revalidated with their ETag at
most every ten minutes. A check copies out only the fields it uses and does
not build objects for the rest of the file.
Those decoded values are released when the check finishes. Failed revalidation
shows a warning while using a valid cached copy.
Platform-specific Homebrew variations are applied for this Mac. Only the Homebrew
prefix used by the installer is scanned, and app ownership is checked against
resolved Caskroom artifacts. Hiding command-line tools also skips their scan.
Icons in the menu are small bitmaps, and the network client does not keep a
response cache.

App and tool installers share one reservation, including all queued apps in a
batch. Concurrent refresh requests share work; changes during a check trigger a
follow-up pass. Sparkle checks exclude non-Mac releases, releases outside their
minimum/maximum macOS range, nested delta enclosures, and malformed appcasts.

## Test

```sh
xcodebuild -project UpdateBar.xcodeproj -scheme UpdateBar -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO test
```

To benchmark uncached versus warm index loading using your existing local index
files (no network requests or installations):

```sh
./script/benchmark_indexes.sh
```

See [the audit and verification notes](docs/audit-2026-10-12.md) for the scope,
measurements, and remaining boundaries of the reliability/performance pass.

## Releases

See [`docs/releasing.md`](docs/releasing.md).

## License

UpdateBar is released under the MIT License.

## App updates

AppUpdater checks [erikrole/UpdateBar](https://github.com/erikrole/UpdateBar/releases) for signed ZIP releases. Normal Release launches check automatically; tests and helper/command launches skip automatic checks. Use **Check for UpdateBar Updates…** in Settings > UpdateBar.

`project.yml` pins the public [AppUpdater](https://github.com/erikrole/AppUpdater) package to `5b5a9411078b79ad92e36bf9d965ecd94b66b420`; rerun XcodeGen after changing the pin. Keep package resolution checked in. App and package targets require **macOS 27**. The host retains its save and busy checks during updater relaunch; no forced-exit fallback is configured.

Published on October 23, 2026 as [UpdateBar 0.1.3](https://github.com/erikrole/UpdateBar/releases/tag/v0.1.3), build 5, from source `5675bd0287983d492af9548a4a1cadf39ed0556e`. The Apple Silicon ZIP requires macOS 27 or later and is Developer ID signed, notarized, and stapled. A SHA-256 checksum and provenance manifest are attached to the release.
