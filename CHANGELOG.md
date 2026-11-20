# Changelog

## Unreleased

- Pin AppUpdater to `e40e410` and reflect live self-update status in Settings and popover Quit state.
- Fall back to per-app stable feeds, public `/releases/latest` HEAD redirects, or local `AppUpdater.Status` when GitHub's anonymous API returns HTTP 403/429, and show clearer 403/429/5xx failure messages.
- Extract third-party ZIP casks with `bsdtar` and validate against escaping symlinks, hard links, and unsupported file types before staging.
- Refresh Login Item status when Settings appears or activates, and add an "Open Login Items Settings…" button when approval is needed.
- Clear delivered update notifications once updates are installed or no updates remain.

## 0.1.7

- Show the installed version, last successful check, and pending restart for apps that use AppUpdater.
- Open those apps to apply updates through their own safety checks.
- Offer verified recovery for a previous app bundle when an update has yet to confirm startup.


## 0.1.5 - 2026-10-27

- Update all now includes my ZIP-only apps (StatBar, Cutdown, SnipBar, Tweaks, TVBar): their GitHub releases install in place, verified against my Team ID, instead of opening the release page. UpdateBar still updates itself through AppUpdater.

## 0.1.4 - 2026-10-26

- Install stable UpdateBar updates automatically at launch (Settings > UpdateBar, on by default). A failed update stops retrying after two tries.

## 0.1.3 - 2026-10-23

- Add signed ZIP self-updates through AppUpdater, preserving save and busy safeguards.
- Publish a notarized Apple Silicon release requiring macOS 27 or later.

## 0.1.1 (3) — 2026-10-23

- Requires macOS 27 or later.
- Fix a startup exception by keeping background-check tolerance below its interval.

- Package updates show “Install…” and explain how to finish in Apple’s Installer.
  Update all includes only updates that UpdateBar can finish itself.
- Preserve recent staged packages across relaunches and skip cleanup while Installer is open.
- Prevent normal Quit from interrupting an active update.
- Show app/tool update progress and successful app-batch results.
- Add explicit release-note controls, Command-R refresh, and selectable failure details.
- Block installer entry points during checks and isolate package-cache regression tests.
