# UpdateBar development

Native Swift 6 macOS 14+ menu bar app. `project.yml` is the XcodeGen source of
truth; regenerate the checked-in project after adding/removing Swift files.
Sparkle is pinned to 2.10.0. No repository-specific visual design system exists;
preserve the current compact AppKit popover and SwiftUI components.

- Build/run: `./script/build_and_run.sh --verify`. This stops UpdateBar first;
  never use it while an app/tool installer is active. Output is `build/dd`.
- Tests: `xcodebuild -project UpdateBar.xcodeproj -scheme UpdateBar -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO test`.
- Read-only live check: `build/dd/Build/Products/Debug/UpdateBar.app/Contents/MacOS/UpdateBar --report`.
- Repeatable index benchmark: `./script/benchmark_indexes.sh`, after the app has
  cached both indexes. Uses temporary copies, not network requests.

`UpdateStore` owns main-actor state and serializes installers. Its injected
collector/install closures let tests exercise races without installing software.
Checker work and the decoded-index actors run away from UI state. Keep Homebrew
ownership tied to resolved Caskroom app paths; uninstall quit IDs can be helpers.
Preserve source precedence in `design-plans/source-precedence.md`.
A cask not installed by Homebrew is only a name match; `HomebrewChecker.identifies` must also
confirm it is the same app (a declared or zap-path bundle ID, else the bundle ID's vendor in the cask's
host). Fetch (com.erole.Fetch) vs the `fetch-app` FTP client is the regression case.
Own `com.erole.*` apps are checked at `erikrole/<Name>`, then `erikrole/<name>-releases` (private source,
public releases: Fetch, Offload).

Own-app GitHub releases with a `.dmg` asset install in place (`DMGInstaller`: download, mount, codesign/Team ID T26T3G8C7Q/spctl check,
quit, swap with backup, relaunch). Casks for apps Homebrew doesn't own (e.g. Claude) with a .dmg/.zip download install in place the same way, verified against the
installed app's own Team ID (`archiveInstall`); .pkg casks (`pkgInstall`) download over https into `~/Library/Caches/UpdateBar/pkg`, verify `pkgutil --check-signature` (Developer ID
Installer, same Team ID) and Gatekeeper, then open the package in Apple's Installer, which asks for the password itself (UpdateBar never
elevates); staged packages are swept at launch. Browsers with an update page keep "Open"/a link.

Tests must use isolated defaults and fixture network responses. Never invoke
`--install`, Homebrew upgrades, or real Sparkle installs merely to test the app.
Do not commit cached indexes, application inventories, live reports, generated
builds, signing material, or personal defaults. Build/report proof is separate
from UI inspection, actual installs, and signed/notarized distribution.
