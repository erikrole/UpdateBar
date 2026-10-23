# Releasing UpdateBar

UpdateBar is distributed directly as a signed and notarized Apple Silicon ZIP
attached to a GitHub Release. Homebrew is intentionally deferred until the app
has a stable release cadence.

## Prerequisites

- Apple Developer Program membership.
- A **Developer ID Application** certificate and private key in the local
  keychain or in the release workflow's imported keychain.
- An App Store Connect API key authorized to submit notarization requests, or a
  local `notarytool` keychain profile.
- Xcode and XcodeGen.

If the checkout does not have a Developer ID Application identity, the release
script stops before archiving and explains what is missing.

## Local release

Use a keychain profile created for `notarytool`:

```sh
TEAM_ID="YOUR_TEAM_ID" \
NOTARY_PROFILE="UpdateBar-notary" \
./scripts/release-macos.sh
```

Or provide an App Store Connect API key directly:

```sh
TEAM_ID="YOUR_TEAM_ID" \
NOTARY_KEY_ID="YOUR_KEY_ID" \
NOTARY_ISSUER_ID="YOUR_ISSUER_ID" \
NOTARY_PRIVATE_KEY_PATH="/path/to/AuthKey_KEYID.p8" \
./scripts/release-macos.sh
```

The script generates a Release archive, exports Developer ID-signed
`UpdateBar.app`, submits a ZIP to Apple's notary service, staples the ticket,
and writes:

```text
.release/UpdateBar-0.1.1-arm64.zip
.release/UpdateBar-0.1.1-arm64.zip.sha256
```

## GitHub release

There is currently no checked-in GitHub Actions release workflow. Publish the
verified local ZIP and checksum with the GitHub CLI, targeting the exact source
commit used for the build. Prepare release notes in a file, then stage a draft:

```sh
gh release create v0.1.1 /path/to/UpdateBar-0.1.1-arm64.zip \
  /path/to/UpdateBar-0.1.1-arm64.zip.sha256 \
  --repo erikrole/UpdateBar --target <build-commit-sha> \
  --title 'UpdateBar 0.1.1' --notes-file /path/to/release-notes.md --draft
```

Verify the uploaded asset digest matches the local checksum, then publish:

```sh
gh release edit v0.1.1 --repo erikrole/UpdateBar --draft=false --latest
```

Version 0.1.1 (build 3) was published on 2026-10-23 at
https://github.com/erikrole/UpdateBar/releases/tag/v0.1.1. It requires Apple Silicon
and macOS 27 or later. The tag points to `eec5fb77b98a1a72d62442a51a26e1b7299c2df3`.

Do not commit certificates, private keys, provisioning assets, or notarization
credentials.

Version 0.1.2 (build 4) was signed, notarized, installed, and published on 2026-10-23:
https://github.com/erikrole/UpdateBar/releases/tag/v0.1.2. Its source commit is
`a1d588f1d57281eb403b3266d9a068700abd5cd6`. See
[release notes](release-notes-0.1.2.md) for the Homebrew relaunch fix and verification.

## Verified updater release: 0.1.3 (build 5)

Published October 23, 2026 at [UpdateBar 0.1.3](https://github.com/erikrole/UpdateBar/releases/tag/v0.1.3). Source commit: `5675bd0287983d492af9548a4a1cadf39ed0556e`. The app and its owned extensions/helpers require macOS 27.0 in Info.plist and Mach-O. The arm64 ZIP is Developer ID signed with Team `T26T3G8C7Q`, accepted by Apple notarization, stapled, and accepted by Gatekeeper after fresh extraction. ZIP/checksum/provenance digests match GitHub. Host tests: 99 reported, 5 skipped, zero failures. AppUpdater’s live download/verification path also passed for this public release.
