# Mac utility family

Adopted October 28, 2026. Four independent native Mac utilities share this design
language. They do not require a launcher, container app, account or shared runtime.

## Names and roles

| Display name | Purpose | Stable repository / target | Icon object | Color field |
| --- | --- | --- | --- | --- |
| **Expand** | Turn abbreviations into snippets | SnipBar | Snippet braces with growing text | Warm orange |
| **Monitor** | See system activity and health | StatBar | Graphite display with metric bars | Blue |
| **Remote** | Control the office TV screens | TVBar | Satin metal remote | Violet |
| **Refresh** | Keep Mac apps and tools current | UpdateBar | App tiles with an update cycle | Green |

Use the individual name in app copy, settings, accessibility labels and README
headings. Use **Expand · Monitor · Remote · Refresh** when showing the family.
A separate umbrella brand has not been chosen. Offload and Fetch stay separate;
Cutdown and Tweaks are not renamed in this adoption.

## Icons

Simple dimensional objects are the shared signature. Use the existing editable
Icon Composer documents as the baseline. Each app has one clear central idea,
few foreground layers, soft depth, consistent lighting and a solid color field.
Keep the shared square platform configuration; let the system render the mask.

- Use restrained glass, satin metal and opaque surfaces where the object warrants
  them. Light direction, depth and visual scale should feel related across all four.
- Keep the object recognizable at small sizes. Avoid name lettering, initial
  badges, tiny decoration, heavy baked shadows and a common badge on every icon.
- Preserve each app's color family in dark appearance with tuned foreground
  contrast. Check default, dark and system monochrome together in Icon Composer.
- Keep vectors and layers editable. Source packages and compiled icon names retain
  their legacy filenames; see this folder's README for the exact resource path.
- Menu bar icons remain crisp monochrome symbols. They communicate state and use
  native rendering; dimensional application artwork belongs in app identity surfaces.

The October 28 layered icons already follow this direction. This naming change
adopts them; it does not claim that a new set of illustrations was produced.

## Native interface

Use SwiftUI controls and macOS scenes, with AppKit for the existing status-item,
window and lifecycle needs. Keep the product's working architecture. No extra
UI framework or shared package is required to follow this guide.

- Use the system font and semantic text styles. Semibold distinguishes headings;
  secondary text handles supporting detail. Use monospaced digits for changing
  measurements. Do not bundle a brand font.
- Use a 4 / 8 / 12 / 16 / 24 / 32-point spacing rhythm. Default to 16-point content
  insets in app-owned panels, 8-point related gaps and 16-point section gaps.
  Native forms, menus and WidgetKit retain their platform spacing.
- Let native controls, popovers and windows supply their materials and appearance.
  Keep content readable and quiet; do not wrap every row in a glass card.
- Respect the user's system accent for interactive controls. Icon color fields
  are identity accents, not a required tint for every button or background.
- Use SF Symbols for actions and status. Pair status color with a symbol or words;
  provide accessible names for icon-only buttons. Preserve keyboard navigation,
  standard shortcuts, reduced motion and increased contrast.
- Keep actions specific: Open Snippets, Check for Updates…, Refresh Channels.
  Use Settings, Open at login and Quit consistently when adding or revising copy.
  Errors explain what happened and the next available action.
- Motion confirms a user action or communicates progress. Avoid persistent decorative
  animation. Keep inactive utilities quiet.

## Product-specific rules

- **Expand:** the menu popover leads to the snippet editor. Keep permission setup
  and save recovery explicit. Never trade typing reliability for decorative motion.
- **Monitor:** retain the 360 × 600-point overview, native disclosures and fixed
  footer. CPU/cores/downloads stay blue, GPU purple, disks teal, uploads orange,
  and healthy memory/battery/network green. Warning and critical colors stay distinct.
- **Remote:** keep the desktop widget and quiet helper. No menu bar remote or
  dashboard. WidgetKit owns widget margins and rendering. Clearly say that status
  is the last command sent, not live feedback from the TV.
- **Refresh:** keep the compact update list and per-app progress, failures and
  installer state. “Opened in Installer” is not “Installed.” Do not interrupt
  an active installer for a cosmetic or naming change.

## Repository presentation and compatibility

README headings and descriptions use the public name, followed by a short
“formerly” bridge. Brand documentation uses this same family table and icon
vocabulary. New screenshots should show the current UI, with consistent scale,
appearance and neutral background. Do not publish fixture previews as live proof.

Keep repository URLs and local paths, Xcode targets/modules, executable and `.app`
filenames, bundle IDs, app groups, widget kinds, URL schemes, Keychain services,
defaults, data paths and release ZIP names stable. `CFBundleDisplayName` and
`CFBundleName` carry the new public identity. The widget extension uses Remote
as its display name. Existing users should retain their data and update route.

This is an adopted design specification and a display-name implementation, not a
claim that every existing view has been redesigned. Apply the rules as individual
surfaces are revised. A release needs its own signed-build, installed-name,
permissions/Login Items, widget registration and update/relaunch acceptance.
