# UpdateBar app icon

`UpdateBar.icon` is the editable Icon Composer source. Separate SVG layers
hold the circular update arrow and four app tiles. The green tile and white
arrow represent keeping a group of applications current.

Open the `.icon` document in Icon Composer to change artwork, materials, or
appearance overrides. The default and dark backgrounds are explicit; monochrome
uses the system rendition. Keep layer art as vectors and retain the shared square
platform configuration.

`project.yml` includes the document as an app resource and sets
`ASSETCATALOG_COMPILER_APPICON_NAME` to `UpdateBar`. Run `xcodegen generate` after
project changes and retain the generated Xcode project. Xcode compiles
`Assets.car`, the fallback `UpdateBar.icns`, and the bundle icon metadata. The
app's existing menu bar presentation is independent of this application icon.

Verified October 27, 2026 with Xcode / Icon Composer 27.1: default, dark, and mono
renders, Developer ID Release build, named bundle icon and compiled resources,
and strict deep signature verification including Sparkle. Build evidence is
local and ignored at `build/icon-verification/release-build.log`. No app logic
changed. Unit tests, live update installation, local installation, notarization,
and distribution were not run for this change.
