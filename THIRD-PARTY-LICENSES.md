# Third-party code

## Ice — removed 2026-09-17

<https://github.com/jordanbaird/Ice> — Copyright © Jordan Baird — **GPL-3.0**

BarT used to contain code from Ice: the `scromble` technique, the tap construction and the
undocumented `CGEvent` window-ID fields, all of which served one purpose — moving other apps'
menu bar items with a simulated ⌘-drag. That engine was removed entirely (issue BT-15). Items are
arranged by the user now, with the ⌘-drag macOS provides natively.

### What remains, and why

`BarT/Engine/Bridging.swift` declares six private CoreGraphics Services functions
(`CGSMainConnectionID`, `CGSGetWindowCount`, `CGSGetOnScreenWindowCount`,
`CGSGetOnScreenWindowList`, `CGSGetProcessMenuBarWindowList`, `CGSGetScreenRectForWindow`). Their
signatures were originally verified against Ice's `Shims/Private.swift`, and the file still says
so, because it is true and because a wrong signature here corrupts memory silently.

These are declarations of *Apple's* undocumented API — facts about an interface, not authored
code. Four of the six are documented identically in the public
[CGSInternal](https://github.com/NUIKit/CGSInternal) header archive, which is not derived from
Ice. `CGSGetProcessMenuBarWindowList` is not among them.

### Licence consequence

Until the removal, BarT was a derivative work of a GPL-3.0 project and licensed accordingly. With
the implementation code gone, that basis is gone too — but **BarT stays under GPL-3.0 for now**.
Changing a licence is a deliberate act, not a side effect of a deletion, and it should happen when
someone has looked at the remaining declarations properly rather than on the strength of this
file. See `docs/PRD.md` §2.
