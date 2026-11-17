---
name: verify
description: Prove a Refresh (UpdateBar) change works before committing or opening a PR; runs the XCTest suite, builds and launches the real debug app, runs the read-only report and looks at the changed UI, then puts the Mac back as it was.
---

# Verify a Refresh change

Goal: evidence, not a green unit test. Run the cheap checks first, then the real app.
Runs on Erik's Mac. Never on a work NAS share: all output goes under `build/verify/`
(ignored by `build/`). Judge every step by its exit code, not by `tail`.

The debug build shares the bundle ID `com.erole.UpdateBar`, the prefs domain and the
caches with the installed `/Applications/UpdateBar.app` (shown as "Refresh"), and both
executables are called `UpdateBar`. So `pkill -x UpdateBar` and `build_and_run.sh` stop
the installed copy too.

## 0. Setup (always)

```bash
mkdir -p build/verify
pgrep -x Installer; pgrep -lf "brew (upgrade|install|fetch|reinstall)"; pgrep -lP "$(pgrep -f '^/Applications/UpdateBar.app/Contents/MacOS/UpdateBar$')"   # want no output
defaults export com.erole.UpdateBar - > build/verify/prefs-before.plist
pgrep -lf /Applications/UpdateBar.app || echo "installed Refresh not running"   # write down which
```

If an installer is active (Apple's Installer, a brew upgrade, or a child process of the
installed app), stop: AGENTS.md forbids `build_and_run.sh` then, and SIGTERM bypasses the
app's own "update still running" quit guard.

## 1. Cheap checks (always, ~30 s; first run longer while packages resolve)

```bash
xcodebuild -project UpdateBar.xcodeproj -scheme UpdateBar -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO test > build/verify/test.log 2>&1; echo "exit $?"
grep -E "Executed [0-9]+ tests" build/verify/test.log | tail -1
grep -E "\*\* TEST (SUCCEEDED|FAILED) \*\*|: error: " build/verify/test.log
```

All tests are XCTest. Report the last `Executed` line (the "All tests" total, printed
twice). Pass = exit 0, `** TEST SUCCEEDED **`, `0 failures` and no `: error:` lines.
The 5 skipped tests are the opt-in live suites (`BrewAppLiveTests`, `DMGInstallerLiveTests`);
never set their `TEST_RUNNER_UPDATEBAR_LIVE_*` variables to verify a change, since they
install real software and need Erik's explicit OK (AGENTS.md).

Only when the diff touches it (not run in the dry run, because it didn't):

| Diff touches | Also run |
|---|---|
| added/removed Swift files, `project.yml` | `xcodegen generate`, then `git diff --stat UpdateBar.xcodeproj` and rerun step 1 |
| index decoding / cache code | `./script/benchmark_indexes.sh` (needs both indexes already cached by the app) |
| release, signing, updater | the steps in `docs/releasing.md` that don't publish; never publish to test |

## 2. Build and launch the real app (always, ~5 s incremental)

```bash
./script/build_and_run.sh --verify > build/verify/build.log 2>&1; echo "exit $?"
tail -1 build/verify/build.log
```

Pass = exit 0 and the last line is `Running: …/build/dd/Build/Products/Debug/UpdateBar.app`.
This quits the installed Refresh. The debug app runs a real check and can post an
"updates available" notification; that's expected.

## 3. Drive the changed flow

Pick what matches the change:

- **Checkers, sources, precedence, version parsing (~1-5 s):**
  ```bash
  build/dd/Build/Products/Debug/UpdateBar.app/Contents/MacOS/UpdateBar --report > build/verify/report.txt 2> build/verify/report.err; echo "exit $?"
  head -1 build/verify/report.txt; grep -E "^(UPDATE|TOOL|FAILED)" build/verify/report.txt
  ```
  Want exit 0 and a first line `N apps, M updates`. Read every `UPDATE` line for the app the
  change is about. `FAILED` lines are evidence to report, not something to hide.
  Never use `--install`.
- **Settings (~5 s):** open it through the app menu (needs Accessibility for your terminal),
  then capture the window:
  ```bash
  PID=$(pgrep -f "Debug/UpdateBar.app/Contents/MacOS/UpdateBar$")
  osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to click menu item \"Settings…\" of menu 1 of menu bar item \"Refresh\" of menu bar 1"
  sleep 2; echo "windows: $(swift .claude/skills/verify/windows.swift "$PID")"   # want 1
  screencapture -x -o -l "$(swift .claude/skills/verify/windows.swift --id "$PID")" build/verify/settings.png
  ```
  Open the PNG and look at the section you changed. Toggle nothing: every switch writes
  shared prefs or system state (Open at login).
- **Popover:** there is no snapshot hook, and on macOS 27 the status item isn't reachable
  through Accessibility (`AXExtrasMenuBar` is missing even for the installed app) or the
  computer-use app list. Ask Erik to click the menu bar icon, or ask for full-screen
  computer use, then screenshot. Never click Update or Update All: those are real installs.
  If you can't look at it, say so in the `Verified:` line.
- **Logs:** `./script/build_and_run.sh --logs` (or `--telemetry`) while reproducing.

Look at the output yourself. "It built" is not verification.

## 4. Clean up (always, before relaunching anything)

```bash
pkill -x UpdateBar; sleep 1; pgrep -lx UpdateBar || echo "none running"
test -s build/verify/prefs-before.plist && defaults delete com.erole.UpdateBar && defaults import com.erole.UpdateBar build/verify/prefs-before.plist
defaults export com.erole.UpdateBar - > build/verify/prefs-after.plist
diff <(plutil -convert xml1 -o - build/verify/prefs-before.plist) <(plutil -convert xml1 -o - build/verify/prefs-after.plist) && echo "prefs identical"
L=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
$L -u build/dd/Build/Products/Debug/UpdateBar.app
$L -u build/dd/Build/Products/Debug/UpdateBar.app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app
$L -dump | grep -E "^path:.*$(basename "$PWD")/build" || echo "no debug builds registered"
```

`defaults import` alone merges: keys the debug run added (e.g. the Settings window frame)
survive it, so delete the domain first. Diff before relaunching, because the installed app
rewrites `AppUpdater.lastCheck` on start. Then, only if it was running in step 0:
`open -a /Applications/UpdateBar.app` (full path, so LaunchServices can't pick a debug copy).

Check that no Login Item points at this checkout (a dry run on 2026-11-17 left debug builds
registered, and they launched instead of the installed apps after a restart):

```bash
sfltool dumpbtm 2>/dev/null | grep -c "URL: .*${PWD#$HOME}/"   # want 0 (BTM shows /Users/<uid>/..., not $HOME, so match the tail)
```

If it isn't 0: quit your copy by PID, then open `/Applications/UpdateBar.app` (it re-registers under the same
bundle ID, which moves the entry back to /Applications) and recheck. If the entry still points here
(an unsigned debug build registers without a bundle ID), unregister and delete this build's `.app`
(build output) so it can't launch at login, and tell Erik to remove the stale entry in System Settings >
General > Login Items.

## 5. Report the evidence

In the commit message, add one trailer line:

```
Verified: xcodebuild test (N tests, S skipped, 0 failures), build_and_run --verify, <what you drove and saw>
```

Use `Verified: none (<reason>)` if you truly couldn't verify. Never leave it out.
In the thread reply, attach or link the screenshot and give the test counts.

## Rules when something fails

- **Three strikes.** Fix and rerun up to 3 rounds. If it still fails, stop and tell Erik
  what fails, what you tried and the exact output. Don't keep going.
- **Never game the check.** No skipping or disabling tests, no adding sleeps, no rerunning
  until it passes, no loosening an assertion to match new output, no editing this skill to
  make your change pass.
- **Flaky test?** Find the root cause. If you can't, say so to Erik with the evidence;
  don't silently delete or retry it.
- **When a bug slips past this skill**, add the check that would have caught it here
  (one line in the table or step 3), in the same PR as the fix.
