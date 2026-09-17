# BarT — Product Requirements

Written in English to match the rest of the repository. Decisions carry the grilling round they
came from `(R2-Q3)`, so nothing here reads as an assumption when it was a choice.

**Revised 2026-09-17** after two findings that arrived late: Ice is GPL-3, not MIT, and the
commercial question turns on exactly the code that came from it. See §7.

## 1. What BarT is

A menu bar manager for macOS: two separator items of BarT's own split the bar into three areas, and
everything to the left of them is pushed out of view until the user asks for it — by clicking
BarT's icon or pressing a shortcut.

The target state is a **curated** menu bar (R1-Q2): roughly half the items stay, the rest is one
click away.

**What BarT does not do any more:** move other apps' items by itself. Arranging which item belongs
to which area is done by the user, with the ⌘-drag macOS provides natively. See §7.

## 2. Distribution

| Decision | Choice | Source |
| --- | --- | --- |
| Audience | Public release, source and binary on GitHub | R2-Q1 |
| Price | **Free.** The paid question is deferred, see §7 | 2026-09-17 |
| macOS | 26.0 only. A macOS 27 version follows once the maintainer runs 27 | R2-Q1 |
| Two OS versions | Eventually **one** app choosing its engine at runtime | R3-Q5 |
| Signing | Unsigned, not notarized; README documents the Gatekeeper path | R2-Q3 |
| Updates | GitHub Releases, manual download, no Sparkle | R2-Q4 |
| Licence | **GPL-3.0 today** (inherited from Ice). Reconsidered once the Ice code is gone — see BT-15 | R2-Q2, corrected |
| Telemetry | None. The app makes no network requests at all | set here |

The Mac App Store is out of the question — BarT uses private CGS APIs.

**Unsigned has a price:** macOS ties permissions to the code signature, so every update
invalidates them and the user has to grant again. This belongs in the README and the welcome
window rather than being discovered.

## 3. Scope of 1.0

Everything below ships before the first public release (R5-Q3). No intermediate version.

### 3.1 Hiding and revealing — the core

- Two separator status items split the bar into Visible / Hidden / Always hidden. This mechanism is
  BarT's own; it is also what Hidden Bar, Dozer and Vanilla use, and it is **not** derived from Ice.
- Left click on BarT's icon reveals "Hidden"; ⌥-click additionally reveals "Always hidden".
- One configurable system-wide shortcut does the same (R3-Q1, R4-Q7).
- A click outside the menu bar collapses; clicks inside do not.
- Auto-collapse after 15 seconds of inactivity (R4-Q4). ✅ done

### 3.2 Arranging items

The user drags items across the separators themselves, with ⌘ held — the gesture macOS has always
offered. macOS remembers the arrangement; BarT does not store an assignment of its own.

BarT's job here is to **explain the gesture** and to **show the result**, not to perform it.

### 3.3 The items view

Read-only. It shows what currently sits in each of the three areas, as the items' **real icons**,
captured via ScreenCaptureKit (R1-Q4) and cached per item (R4-Q3).

This is the one thing the free competition does not offer: seeing which icon ended up where without
expanding the bar and guessing. It cannot change anything — that is §3.2's job.

Sections are wrapping grids (R4-Q1). Without the screen recording permission the view falls back to
what it can determine without it, and says so.

### 3.4 Permissions

With the drag engine gone, BarT needs **no accessibility permission at all**. Enumerating menu bar
windows through the CGS list works without it; it was needed only to attribute items to their
owning app for the drags.

What remains is **screen recording**, and only for the icons in §3.3. It is requested the first
time that view is opened, never at launch (R2-Q5).

A welcome window on first launch (R2-Q3) explains in two sentences what BarT does and how to move
items with ⌘-drag.

### 3.5 Settings

Two tabs (R5-Q1): General holds launch at login, the screen recording state, the shortcut recorder
and the auto-collapse note. Items holds §3.3.

## 4. Explicit non-goals for 1.0

- **Moving items automatically.** Removed deliberately, see §7.
- **Multi-display**: main screen only (R4-Q5), documented in the README.
- **Ordering within a section** (R4-Q3) — moot now that BarT does not arrange anything.
- Auto-update, notarization, localisation, telemetry.

## 5. Known limits to document, not fix

- Items macOS pins itself (clock, Control Center) cannot be moved by anyone, including the user.
- Permissions are lost on every update (§2).
- The separator mechanism depends on macOS behaviour, not on an SDK version.

## 6. After 1.0

- **macOS 27 assertion engine.** Bartender 7 advertises "zero mouse interruptions" — the same
  technique. It restores automatic arranging *without* any foreign code, and it is the point at
  which a paid version becomes defensible (§7). The `HideEngine` protocol is introduced then, not
  before (R3-Q5).
- Sparkle, notarization, multi-display.

## 7. Why the drag engine is being removed

The simulated ⌘-drag (`scromble`), the event tap and the CGS signatures came from
[Ice](https://github.com/jordanbaird/Ice), which is **GPL-3.0** — not MIT, as six source comments
and the README claimed for weeks. GPL-3 is copyleft, so BarT inherits it on distribution.

That does not forbid selling BarT; it makes selling pointless, because every buyer may pass the
source on. Measured against the market, a paid BarT would sit next to Vanilla Pro (~10 $ for
almost exactly this feature set) and below Bartender 7 (21.79 € for far more), with two good free
competitors alongside.

The decision (2026-09-17): **take the Ice code out, ship for free, revisit the price when the
assertion engine makes BarT do something the free competition cannot.** What is lost in the
meantime is automatic arranging — which the user can do themselves in about a minute, once.

What this buys: no foreign code, no licence constraint, no injected mouse events, no accessibility
permission, and the most fragile part of the app gone.
