# BarT

A Bartender clone for macOS — a menu bar management app. Items you rarely need sit out of sight and come back for a moment when you click BarT's own icon.

Tested on macOS 26. Finding the menu bar's windows relies on private CGS calls, so BarT is tied to the behaviour of that OS version.

## Requirements

**Important:** you need the full Xcode IDE, not just the Command Line Tools.

Check whether Xcode is installed:
```bash
xcode-select -p
```

This should print `/Applications/Xcode.app/Contents/Developer`. If it does not (because only the Command Line Tools are installed, say), install Xcode from the App Store and run:
```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

Also required:
- **xcodegen** (to turn `project.yml` into an Xcode project): `brew install xcodegen`

## Building

```bash
xcodegen generate
open BarT.xcodeproj
```

In Xcode: `Product` → `Build`, or `Cmd+B`.

## Security & sandboxing

`BarT.entitlements` disables the App Sandbox (`com.apple.security.app-sandbox = false`). A sandboxed app cannot read the menu bar's window list through the private CGS calls BarT is built on.

## Usage

- **Left click** on the BarT icon temporarily reveals the hidden items; another click hides them again. Items in “Always hidden” stay away — that is exactly what the section is for.
- **⌥-click** additionally reveals “Always hidden”.
- **⌃⌥⌘B** does the same as a left click, system-wide.
- A click anywhere outside the menu bar collapses it again. Clicks *inside* the menu bar do not — otherwise the item you just clicked would be pulled out from under the cursor. Without any interaction it collapses by itself after 15 seconds.
- **Right click** opens the menu (about, the welcome window, settings, quit). Holding **⌥** while the menu opens reveals the debug tools.

## Arranging items: ⌘-drag

**BarT never moves an item.** Deciding what is hidden is a gesture macOS has always offered and almost nobody knows:

> Hold **⌘** and drag an item along the menu bar.

What you drag it *past* is the point. BarT splits the bar into three areas with two status items of its own, which show up as small `‹` markers — the separators:

```
[ Always hidden ]  ‹  [ Hidden ]  ‹  [ Visible ]  «BarT»
```

- Drag an item **left** past the first `‹` and it is hidden; past the second one as well and it stays away even when you reveal.
- Drag it **right** again to bring it back.
- The separators are only on screen **while the hidden items are revealed** — click BarT's icon first, then ⌘-drag. A plain click brings out the first `‹`; ⌥-click brings out the second one as well.
- macOS remembers the arrangement itself. BarT stores nothing: the **Items** tab in the settings shows where things currently sit, as the items' real icons, and cannot change any of it.

Items macOS pins itself — the clock, Control Center — cannot be dragged at all. That is a macOS rule, not a BarT limitation.

## Permissions

BarT needs **no accessibility permission**. The one permission it asks for is **screen recording**, and only to read the icons and titles of your menu bar items for the Items tab — macOS hands out neither without it. BarT makes no network requests and records nothing.

It is asked for the first time you open the Items tab, never at launch. Because BarT is unsigned, macOS ties the grant to that exact build: **after every update you have to allow it again.**

## Current status

Working:

- Enumeration of every menu bar item through the CGS window list
- All three sections, and the items' real icons in the settings, captured with ScreenCaptureKit
- Revealing by click, ⌥-click and global hotkey; collapsing beside the bar or after 15 seconds
- Launch at login

Still open:

- The hotkey is hard-wired (⌃⌥⌘B); on a collision the settings say so, but it cannot be changed yet
- Main screen only

Behind the ⌥-only debug menu item “Run self-tests” sit the checks that are only possible on a running system: the separator order (macOS has to place a new status item to the left of the existing ones — the entire section assignment rests on that), the display-name cleanup, the icon capture, and the hotkey registration. All of them also run without the menu:

```bash
BART_SELF_TEST=1 "$(ls -d ~/Library/Developer/Xcode/DerivedData/BarT-*/Build/Products/Debug/BarT.app)/Contents/MacOS/BarT"
```

## Licence

BarT is free software under the **GPL-3.0** — see [LICENSE](LICENSE).
Copyright © 2026 André Duhme.

That is not a free choice: BarT contains code from [Ice](https://github.com/jordanbaird/Ice)
(GPL-3.0) by Jordan Baird, which makes BarT a derivative work. Every location is listed in
[THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md) and marked in the source. The drag technique
itself (`scromble`, the windowID fields in `CGEvent`) is the most substantial part of it.
