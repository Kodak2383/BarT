# BarT

Your menu bar, as long or as short as you want it. Items you rarely need sit out of sight and come
back for a moment when you click BarT's icon.

<!-- Screenshot goes here with the 1.0 release — see docs/issues/BT-14.md. -->

## What it does

BarT splits the menu bar into three areas and keeps two of them out of sight:

```
[ Always hidden ]  ‹  [ Hidden ]  ‹  [ Visible ]  «BarT»
```

- **Visible** — always in the bar.
- **Hidden** — comes back for a moment when you click BarT's icon or press the shortcut.
- **Always hidden** — stays away even then; only an ⌥-click brings it out.

Which item goes where is your own ⌘-drag in the menu bar (see below). **BarT never moves an item
itself**, and it stores nothing about your arrangement — macOS already remembers it.

## Will it run here?

- **macOS 26.** BarT finds the menu bar's windows through private CoreGraphics calls, which are
  not API and change without notice. It is tested on macOS 26 and pinned to how that version
  behaves. A major system update can break it; that is the deal these calls come with.
- **Your main screen.** Items on a second display are not managed.

## Installing

BarT is **not signed and not notarised**: there is no Apple developer certificate behind it, so
macOS treats it as software from an unidentified developer.

1. Download the zip from the latest release and unpack it.
2. Move **BarT.app** to your **Applications** folder.
3. **Right-click** the app and choose **Open**, then **Open** again in the dialog. Double-clicking
   the first time only offers you a Cancel button.

If macOS blocks it anyway: **System Settings › Privacy & Security**, scroll to the bottom, and
click **Open Anyway** next to the message about BarT.

BarT has no window of its own. Once it runs, its icon is in the menu bar — the welcome window on
first launch explains the rest.

## What BarT asks for

**One permission: screen recording.** macOS hands out neither the icon nor the real name of
another app's menu bar item without it, and those are what the Items tab shows you. BarT asks the
first time you open that tab, never at launch, and it works without it — the Items tab just falls
back to names like "Control Center" for everything.

It records nothing, and BarT makes **no network requests of any kind**: no telemetry, no update
check, no analytics. There is no networking code in it at all.

**After every update you have to allow it again.** Because BarT is unsigned, macOS ties the grant
to that exact build and treats the next version as a different app. This is not a bug and there is
no way around it short of signing.

It needs **no accessibility permission**. An earlier version did; that machinery is gone.

## Using it

- **Left click** the BarT icon reveals the hidden items; another click hides them again.
  "Always hidden" stays away — that is what the section is for.
- **⌥-click** additionally reveals "Always hidden".
- **⌃⌥⌘B** does the same as a left click, system-wide. It is configurable in
  **Settings › General**: click the field, press the combination you want. BarT turns down
  anything macOS has already claimed (⌘Space, for instance) and anything without ⌃, ⌥ or ⌘ — the
  shortcut you had keeps working until a new one is accepted.
- A click **outside** the menu bar collapses it again. Clicks *inside* the bar do not, otherwise
  the item you just clicked would be pulled out from under the cursor. Left alone it collapses by
  itself after 15 seconds.
- **Right click** opens the menu: about, the welcome window, settings, quit.

## Arranging items: ⌘-drag

Deciding what is hidden is a gesture macOS has always offered and almost nobody knows:

> Hold **⌘** and drag an item along the menu bar.

What you drag it *past* is the point. BarT's two areas are marked by two status items of its own,
which show up as small `‹` markers — the separators.

- Drag an item **left** past the first `‹` and it is hidden; past the second one as well and it
  stays away even when you reveal.
- Drag it **right** again to bring it back.
- The separators are only on screen **while the hidden items are revealed** — click BarT's icon
  first, then ⌘-drag. A plain click brings out the first `‹`; ⌥-click brings out the second one
  as well.
- The **Items** tab in the settings shows where everything currently sits, with the items' real
  icons. It is a picture, not a control: nothing in it can be moved.

## What it cannot do

- **Move items for you.** Arranging is the ⌘-drag above, once, by hand.
- **Touch items macOS pins itself** — the clock and Control Center cannot be dragged at all. That
  is a system rule, not a BarT limitation.
- **Manage a second display.** Main screen only.
- **Survive every system update.** The private calls BarT reads the menu bar with are
  undocumented; a macOS update may change or remove them, and then BarT stops working until it is
  fixed.

## Building from source

You need the full **Xcode**, not just the Command Line Tools. Check with:

```bash
xcode-select -p
```

That should print `/Applications/Xcode.app/Contents/Developer`. If it does not, install Xcode from
the App Store and run:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

`project.yml` is the source of truth for the Xcode project, so **xcodegen** is needed as well
(`brew install xcodegen`):

```bash
xcodegen generate
open BarT.xcodeproj
```

Then `Product › Build` in Xcode, or `⌘B`.

`BarT.entitlements` disables the App Sandbox on purpose: a sandboxed app cannot read the menu
bar's window list through the private CGS calls BarT is built on.

`scripts/gates.sh` is the one command that checks a change — it builds, runs the self-tests,
checks the two style rules, and runs the issue's own verification script if it has one. The
self-tests are the checks that only work on a running system (the separator order, the name
cleanup, the icon capture, the shortcut registration) and also run on their own:

```bash
BART_SELF_TEST=1 "$(ls -d ~/Library/Developer/Xcode/DerivedData/BarT-*/Build/Products/Debug/BarT.app)/Contents/MacOS/BarT"
```

The same checks sit behind the ⌥-only "Run self-tests" item in the right-click menu.

## Licence

BarT is free software under the **GPL-3.0** — see [LICENSE](LICENSE).
Copyright © 2026 André Duhme.

BarT used to contain code from [Ice](https://github.com/jordanbaird/Ice) (GPL-3.0) by Jordan
Baird — the simulated ⌘-drag that moved items automatically. That code was removed entirely. What
is left is six declarations of Apple's own private CoreGraphics interface, five of which come
from a public header archive that has nothing to do with Ice.
[THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md) goes through them one at a time.

GPL-3.0 stays regardless: changing a licence is a deliberate act, not a side effect of a deletion.
