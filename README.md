# UpdateBar

UpdateBar is a native macOS menu bar utility that tells you which of your apps
have updates and gets you to them in one click. It is a from-scratch take on
the idea behind [Latest](https://github.com/mangerlahn/Latest); no Latest code
is used.

- Lives in the menu bar with a count of pending updates and rechecks in the
  background (every 6 hours by default), with a notification when something new
  appears.
- Checks four sources: the Mac App Store, each app's own Sparkle feed, Homebrew
  casks, and GitHub Releases. Apps with a `com.erole.` bundle ID are linked to
  `erikrole/<name>` automatically.
- Shows each app once. An app's own updater decides: when the App Store or its
  Sparkle feed says it is current, a Homebrew or GitHub hint can't override that.
- Compares against the version actually on disk, so apps that updated themselves
  aren't flagged the way `brew outdated --greedy` flags them.
- Shows release notes inline, and lets you skip a version or ignore an app.
- One-click updates: `brew upgrade --cask` for Homebrew installs (as you, never
  with admin rights), in-place installs for Sparkle apps that sign their updates
  (via the embedded [Sparkle](https://sparkle-project.org) framework, verified
  against each app's own EdDSA key; the app quits and reopens if it was running),
  and the App Store's Updates page for store apps. "Update all" runs every
  in-place update one after another.

Out of scope on purpose: a root install helper and Apple's private App Store
frameworks. Feeds that only work over plain HTTP are reported, not trusted.

## Build and run

Requirements: macOS 14 or later, Xcode, and XcodeGen.

```sh
xcodegen generate
xcodebuild -project UpdateBar.xcodeproj -scheme UpdateBar -configuration Debug CODE_SIGNING_ALLOWED=NO build
open ~/Library/Developer/Xcode/DerivedData/UpdateBar-*/Build/Products/Debug/UpdateBar.app
```

`UpdateBar --report` runs one check, prints what it found and exits, which is the
quickest way to debug a wrong result:

```sh
UpdateBar.app/Contents/MacOS/UpdateBar --report
UpdateBar.app/Contents/MacOS/UpdateBar --install <bundle ID>   # installs one pending update, then exits
```

The Homebrew cask index (~20 MB) is cached at
`~/Library/Application Support/UpdateBar/cask.json` for six hours.

## Test

```sh
xcodebuild -project UpdateBar.xcodeproj -scheme UpdateBar -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

## Releases

See [`docs/releasing.md`](docs/releasing.md).

## License

UpdateBar is released under the MIT License.
