# Changelog

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
