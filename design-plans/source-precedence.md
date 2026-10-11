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
