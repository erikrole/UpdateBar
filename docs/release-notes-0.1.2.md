# UpdateBar 0.1.2

Homebrew app updates now reopen apps that were running before the update.

- Download the update before asking the app to quit.
- Wait for a normal exit without force-quitting unsaved work.
- Reopen running apps after installation; leave previously closed apps closed.
- Attempt to restore the running app if Homebrew fails.
- Keep the installer reserved through relaunch, then refresh the update list.
- Use the same lifecycle for menu and command-line updates.

Validation: 99 tests, five opt-in live tests skipped, zero failures. A separately
run live test upgraded CodexBar 0.79.0 to 0.80.0 through the production Homebrew
action/store pipeline using an empty download cache. Download checksum,
installation, automatic relaunch with a new process, and automatic list refresh
passed. The live test used an integration harness rather than a menu click.

Requires Apple Silicon and macOS 27 or later. Distributed as a Developer ID-signed,
notarized ZIP with a SHA-256 checksum.
