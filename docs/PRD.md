# BarT — Product Requirements

Written in English to match the rest of the repository, which goes public.
Every decision below was made by the maintainer in the grilling session of 2026-09-17;
the round/question it came from is noted as `(R2-Q3)` so nothing here looks like an
assumption when it was a choice.

## 1. What BarT is

A menu bar manager for macOS in the tradition of Bartender: menu bar items are assigned to
three sections — always visible, hidden, always hidden — and the hidden ones are revealed on
demand by clicking BarT's own icon or pressing a keyboard shortcut.

The target state for a typical user is a **curated** menu bar (R1-Q2): roughly half the items
stay put, the rest is one click away. Not an empty bar, and not just two offenders tucked away.

## 2. Distribution

| Decision | Choice | Source |
| --- | --- | --- |
| Audience | Public release, source and binary on GitHub | R2-Q1 |
| macOS | 26.0 only. A macOS 27 version follows once the maintainer runs 27 | R2-Q1 |
| Two OS versions | Eventually **one** app choosing its engine at runtime, not two builds | R3-Q5 |
| Signing | Unsigned, not notarized; README documents the Gatekeeper path | R2-Q3 |
| Updates | GitHub Releases, manual download, no Sparkle | R2-Q4 |
| Licence | BarT under MIT; Ice's MIT notice shipped alongside | R2-Q2 |
| Telemetry | None. The app makes no network requests at all | set here |

The Mac App Store is out of the question — BarT uses private CGS APIs.

**Consequence of shipping unsigned:** macOS ties accessibility and screen recording permissions
to the code signature. Without a stable Developer ID, every update invalidates them and the user
has to grant both again. This must be stated in the README and in the welcome window rather than
discovered.

## 3. Scope of 1.0

The maintainer chose the complete cut (R5-Q3): **everything below ships before the first public
release.** No intermediate 0.2.

### 3.1 First run and permissions

- A **welcome window** on first launch (R2-Q3) explains in two sentences what BarT does and why
  it needs the accessibility permission, with a button that triggers the system dialog.
- The accessibility status is checked **live** (on window activation), not once when the settings
  window opens. Granting the permission and coming back must show the new state.
- While the permission is missing, the items view shows an explanation and a button — **never a
  list of items**, because without the permission every item is misattributed to Control Center
  and the names are wrong.
- The **screen recording** permission is requested separately and later (R2-Q5): the first time
  the items view is opened, in the moment its benefit is visible. Not during the welcome window.
- As the last step of the welcome window, BarT offers a **starting point** (R4-Q6, R5-Q2): it
  proposes moving everything except clock, battery, Wi-Fi and Control Center to "Hidden", shows
  what that would look like, and applies it only on a button press. "Set up myself" is an equal
  choice, not a fine-print escape.

### 3.2 The items view

- Items are shown as their **real icons**, captured from the menu bar via ScreenCaptureKit
  (R1-Q4). This is what turns the window from a configuration table into a picture of the user's
  own menu bar.
- Each section is a **grid** that wraps onto more rows as needed (R4-Q1), not a single scrolling
  row: it stays usable at 8 items and at 40.
- Icons are **cached per item** and fetched once (R4-Q3). A frozen CPU readout in the list is
  harmless; a window that continuously captures screen content is not.
- Without the screen recording permission the view falls back to names — it does not break.
- Items move between sections by **dragging** and, equally, through a **context menu** on each
  icon (R4-Q2). The context menu is what keeps the view usable by keyboard and VoiceOver once
  the per-row pickers are gone; it is not an afterthought.
- Ordering **within** a section is not offered (R4-Q3). The drag technique cannot position
  neighbouring items independently — that limit is what the oscillation brake exists for, and
  sorting inside a section would turn a rare failure into the normal case.

### 3.3 Revealing and collapsing

- Left click on BarT's icon reveals "Hidden"; ⌥-click additionally reveals "Always hidden".
- One configurable system-wide shortcut does the same (R3-Q1, R4-Q7). Exactly one — the ⌥
  variant stays a click gesture, and a shortcut for the settings window is not worth a third
  binding.
- A click outside the menu bar collapses. Clicks inside do not.
- **Auto-collapse after 15 seconds** (R4-Q4), fixed, not configurable.

### 3.4 Settings

Two tabs (R5-Q1): "General" and "Items". Both tabs must carry accessibility names — today they
announce themselves as "radio button 1" and "radio button 2".

General holds: launch at login, both permission states, the shortcut recorder, and the
auto-collapse behaviour.

### 3.5 When an item cannot be placed

Two physically adjacent items cannot be positioned independently; after three attempts the
oscillation brake gives up. The current full-paragraph grey box is replaced by (R4-Q4):
a one-line summary naming the item, a disclosure for the explanation, a **Retry** button, and a
way to dismiss it.

## 4. Explicit non-goals for 1.0

- **Multi-display**: only the main screen is managed (R4-Q5). Other displays are left alone, and
  the README says so.
- **Ordering within a section** (R4-Q3).
- **Auto-update / Sparkle** (R2-Q4) — reconsider at 0.3, since an app built on private APIs can
  break with any macOS update.
- **Notarization** (R2-Q3) — reconsider if the unsigned path turns out to cost more users than
  the developer programme costs money.
- **Localisation**: English only.
- **Telemetry or crash reporting**: none.

## 5. Known limits to document, not fix

- Items macOS pins itself (clock, Control Center) cannot be moved.
- Permissions are lost on every update (see §2).
- The drag engine depends on macOS 26 behaviour, not on an SDK version — a system update can
  break it.

## 6. After 1.0

- macOS 27 support via a second engine, selected at runtime; the `HideEngine` protocol is
  introduced at that point and not before (R3-Q5).
- Sparkle, notarization, multi-display, ordering within a section.
