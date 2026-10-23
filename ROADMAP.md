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

- Exercise real Sparkle and Homebrew installs with specifically chosen updates,
  including running-app relaunch and failures requiring a Terminal password.
- Verify the menu visually on macOS 14 and newer, plus native/Rosetta and Intel
  Homebrew setups. Secondary Homebrew prefixes are deliberately excluded.
- Profile a larger app library with Instruments; current benchmark isolates
  index loading and does not measure total network-check latency.
- Prepare a signed/notarized release through `scripts/release-macos.sh` when
  release distribution is requested.

See `docs/audit-2026-10-12.md` for observed verification and remaining boundaries.

Verification on 2026-10-23: the Xcode test suite passed (96 executed, four opt-in
live-install tests skipped, zero failures). The local build/launch check passed,
and a read-only live report completed without source failures. Xcode emitted only
its App Intents metadata-extraction warning (this app has no App Intents dependency).
UI automation timed out, so visual/keyboard inspection remains open. No real app
updates, signed release, or installed-copy replacement were performed in this pass.
