# BarT

A Bartender clone for macOS — a menu bar management app. Items can be hidden, revealed again temporarily by clicking BarT's own icon, and the assignment survives a restart.

Tested on macOS 26. The engine relies on private CGS calls and simulated Cmd-drags (see `DragHideEngine`), so it is tied to the behaviour of that OS version.

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

`BarT.entitlements` disables the App Sandbox (`com.apple.security.app-sandbox = false`). That is necessary because BarT has to drive other applications' processes through the Accessibility API — something the macOS App Sandbox does not permit.

## Usage

- **Left click** on the BarT icon temporarily reveals the hidden items; another click hides them again. Items in “Always hidden” stay away — that is exactly what the section is for.
- **⌥-click** additionally reveals “Always hidden”.
- **⌃⌥⌘B** does the same as a left click, system-wide.
- A click anywhere outside the menu bar collapses it again. Clicks *inside* the menu bar do not — otherwise the item you just clicked would be pulled out from under the cursor.
- **Right click** opens the menu (about, settings, quit). Holding **⌥** while the menu opens reveals the debug tools.
- Under **Items** in the settings, every menu bar item is assigned one of the three sections, grouped by where it currently sits. The assignment is stored in `UserDefaults` and restored at launch.

Items are named from the accessibility hierarchy where the owning app supplies something — “Bluetooth”, “Stats – CPU: Mini” — and Apple's menu extras additionally carry a stable identifier (`com.apple.menuextra.wifi`), which is what the assignment is stored under. Third-party items fall back to a positional key, so rearranging identically named items of the same app can still shift their assignment.

To make that work, the bar is internally split into three areas, separated by two status items of BarT's own (invisible under normal circumstances):

```
[ Visible ] [hidden separator] [ Hidden ] [alwaysHidden separator] [ Always hidden ]
```

Moving other apps' items requires the **Accessibility** permission; without it the owner lookup is wrong as well (every item ends up attributed to Control Center). It can be granted from the settings under “General”.

## Current status

Working:

- Enumeration of all menu bar items including the real owning app (CGS window list + `kAXExtrasMenuBarAttribute`)
- All three sections, filled via a simulated Cmd-drag next to the matching separator
- Persistent layout, revealing by click, ⌥-click and global hotkey, collapsing by clicking beside it
- Oscillation brake: two physically adjacent items cannot be positioned independently — a drag only guarantees the position of the dragged item, and its neighbour slides along. Rather than correcting forever, the app gives up after three attempts and reports it in the settings

Still open:

- The hotkey is hard-wired (⌃⌥⌘B); on a collision the settings say so, but it cannot be changed
- No collapse on a timer, only by clicking beside it
- Items macOS pins itself (clock, Control Center) cannot be moved
- “Launch at login” is wired up but untested. It could not have worked before the bundle ID was fixed, since `SMAppService` had nothing to tie the app to

Behind the ⌥-only debug menu item “Run self-tests” sit the self-tests of `MenuBarLayout` and `OscillationGuard`, plus two checks that are only possible on a running system: the separator order (macOS has to place a new status item to the left of the existing ones — the entire section assignment rests on that) and the hotkey registration. All of them also run without the menu:

```bash
BART_SELF_TEST=1 "$(ls -d ~/Library/Developer/Xcode/DerivedData/BarT-*/Build/Products/Debug/BarT.app)/Contents/MacOS/BarT"
```

## Credits

The drag technique (`scromble`, the windowID fields in `CGEvent`) comes from [Ice](https://github.com/jordanbaird/Ice) (MIT).
