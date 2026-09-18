BarT hides the part of your menu bar you rarely need and brings it back for a moment when you ask.
Which item goes where is your own ⌘-drag — BarT never moves anything itself.

## Opening it the first time

BarT is **not signed and not notarised**. macOS will not let a double-click open it.

1. Move **BarT.app** to your **Applications** folder.
2. **Right-click** it and choose **Open**, then **Open** again in the dialog.

If it is blocked anyway: **System Settings › Privacy & Security**, scroll to the bottom, **Open
Anyway**.

BarT has no window of its own. Once it runs, its icon is in the menu bar and a welcome window
explains the rest.

## What it asks for

One permission: **screen recording**, asked the first time you open the Items tab, never at launch.
macOS hands out neither the icons nor the real names of menu bar items without it. BarT records
nothing, makes no network requests, and sends no telemetry.

**Every update asks again.** Because BarT is unsigned, macOS ties the grant to that exact build and
treats the next version as a different app. There is no way around that short of signing.

## Requirements

- **macOS 26.** BarT reads the menu bar through private CoreGraphics calls that are pinned to how
  that version behaves. A major system update can break it.
- **Apple Silicon.** This build is arm64 only. On an Intel Mac, build from source.

## Known limits

- BarT does not move items for you. Arranging is the ⌘-drag, once, by hand.
- Items macOS pins itself — the clock, Control Center — cannot be dragged at all.
- Main screen only.
- The Items tab shows names instead of icons for the hidden sections until you have revealed them
  once: a window that is not on screen cannot be photographed.

## Licence

GPL-3.0. The source, the third-party notices and the full provenance of the private API
declarations are in the repository.
