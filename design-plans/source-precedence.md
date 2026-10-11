# Source precedence

Each checker reports two things: updates it found, and the apps it is
authoritative for and answered about (`covered`).

| Source | Authoritative for | Fallback for |
|---|---|---|
| App Store | apps with `_MASReceipt` | — |
| Sparkle | apps with `SUFeedURL` whose feed answered | — |
| Homebrew | casks present in the Caskroom | other apps whose bundle name matches exactly one cask (bundle ID must agree when the cask names one, and the major version must be within 5) |
| GitHub | apps with a linked repo that has a release | — |

`UpdateResolver` picks, per app, the highest-ranked covering source. If it found
an update, that is the row; if it found none, the app is current and fallback
hints are dropped. Only when nothing covered the app does the best hint show.

Sparkle follows Sparkle's own rule (the build number decides) with one veto: a
readable version that went backwards never counts as an update. That handles
feeds like Dia's, whose short version is decorated as "1.52.0 (88431)".

# In-place Sparkle installs

Sparkle 2.10 (MIT, pinned in `project.yml`) is embedded and driven with the
target app as both host and application bundle, so Sparkle reads that app's own
feed and verifies the download against that app's own `SUPublicEDKey`. Only apps
that ship an EdDSA key get the in-place Update button; the rest open the app.

`SilentUserDriver` answers Sparkle the way a person pressing Install would and
reports progress to the row. Sparkle quits a running app, installs, and relaunches
it only if it was open before. Stable channel only. If an app lives in a
root-owned location, Sparkle's own installer asks for an admin password;
UpdateBar has no privileged helper of its own.

Side effect: Sparkle records its last-check time in the target app's own
defaults domain, as it would if the app had checked itself.

Verified 2026-10-11 by updating CodexBar 0.74.0 → 0.74.1 while it was running:
it quit, updated, relaunched, and `codesign --verify --deep --strict` passed.
