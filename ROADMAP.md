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

- Exercise real Homebrew installs with specifically chosen updates, including
  failures requiring a Terminal password. The Sparkle success path is verified below.
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
