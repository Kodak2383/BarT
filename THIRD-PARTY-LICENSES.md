# Third-party code

## Ice — removed 2026-09-17

<https://github.com/jordanbaird/Ice> — Copyright © Jordan Baird — **GPL-3.0**

BarT used to contain code from Ice: the `scromble` technique, the tap construction and the
undocumented `CGEvent` window-ID fields, all of which served one purpose — moving other apps'
menu bar items with a simulated ⌘-drag. That engine was removed entirely (issue BT-15), together
with the two private declarations only it needed (`GetProcessForPID`, `CGSEventIsAppUnresponsive`).
Items are arranged by the user now, with the ⌘-drag macOS provides natively.

Nothing that *does* anything came from Ice any more. The separator mechanism — two status items
of BarT's own, one of them 10,000 points wide — is BarT's own and is the same approach Hidden Bar,
Dozer and Vanilla take.

## What remains, and why

`BarT/Engine/Bridging.swift` declares six private CoreGraphics Services functions:
`CGSMainConnectionID`, `CGSGetWindowCount`, `CGSGetOnScreenWindowCount`, `CGSGetOnScreenWindowList`,
`CGSGetProcessMenuBarWindowList` and `CGSGetScreenRectForWindow`. Everything that *uses* them —
the `CGSBridge` facade, the buffer sizing, the error handling — is BarT's own code.

Checked 2026-09-18, one declaration at a time:

- **Five of the six** — all but `CGSGetProcessMenuBarWindowList` — are declared in the public
  [CGSInternal](https://github.com/NUIKit/CGSInternal) header archive (`CGSConnection.h`,
  `CGSWindow.h`), which is not derived from Ice. Same types, same order, same parameter names
  (`cid`, `targetCID`, `count`, `list`, `outCount`, `wid`, `outRect`). Ice's own Swift
  declarations follow that header too, which is why all three agree character for character:
  there is one way to write these, not several.
- **`CGSGetProcessMenuBarWindowList`** is in no public header that could be found — not in
  CGSInternal, not in yabai's `extern.h` (MIT), which declares two dozen other `SLS*` menu bar
  calls. Its Swift signature was taken from Ice and mirrors its sibling
  `CGSGetOnScreenWindowList` parameter for parameter. The **symbol** is Apple's: CoreGraphics
  re-exports it from SkyLight, verified locally with `dyld_info -exports`.

These are declarations of *Apple's* undocumented interface, not authored logic. The one that has
Ice as its only traceable source is named as such in `Bridging.swift`, in place.

## Licence consequence

Until the removal, BarT was a derivative work of a GPL-3.0 project and licensed accordingly.

**BarT stays under GPL-3.0.** Not because it has to — six declarations of a foreign API are a
thin basis for that claim, and five of them have an Ice-independent source — but because changing
a licence is a deliberate act, not a side effect of a deletion, and because staying makes the
question moot at no cost.

The about panel therefore states the licence and nothing more (2026-09-18). It used to add
"It contains code from Ice (GPL-3.0) by Jordan Baird", which overstated what is there: a reader
took it to mean foreign code is running in the app. The provenance lives here instead, where it
can be written out properly.

What would have to happen to relicense: write `CGSGetProcessMenuBarWindowList`'s declaration from
an Ice-independent basis — Apple's own exported symbol plus the sibling call's shape — and drop
the reference. Everything else is already clear. This has not been done, and it is not a
prerequisite for anything BarT currently does.

*None of the above is legal advice; it is a record of what was checked and when.*
