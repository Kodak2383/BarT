# BarT — Board

Scope and decisions: [PRD.md](PRD.md). One file per issue in [issues/](issues/) — each written to
be handed to a fresh session on its own.

**Revised 2026-09-17.** The Ice code comes out (PRD §7), which deletes automatic arranging and with
it four issues. BarT ships free; the price question waits for the assertion engine.

**Mode markers**
- 🤖 **AFK** — I can build *and* verify it alone (build, self-tests, screenshots, `System Events`).
- 👤 **HITL** — needs you somewhere, and the issue says where. Three things I cannot do: grant a
  permission, judge whether something *feels* right, use your GitHub account.

## Columns

### Ready — unblocked, startable now
| ID | Title | Mode |
| --- | --- | --- |
| [BT-04](issues/BT-04.md) | Welcome window on first launch | 👤 HITL |
| [BT-16](issues/BT-16.md) | Teach the ⌘-drag | 👤 HITL |
| [BT-11](issues/BT-11.md) | Configurable shortcut | 👤 HITL |
| [BT-07](issues/BT-07.md) | The section grid, read-only | 🤖 AFK |

### Blocked
| ID | Title | Mode | Waiting for |
| --- | --- | --- | --- |
| [BT-02](issues/BT-02.md) | README for a public audience | 🤖 AFK | BT-07, BT-16 |
| [BT-14](issues/BT-14.md) | Publish 1.0 | 👤 HITL | everything |

### Done
| ID | Title | Verified by |
| --- | --- | --- |
| [BT-12](issues/BT-12.md) | Auto-collapse after 15 seconds | Icon `»` → hotkey → `«` → 16 s → `»`, captured live |
| [BT-01](issues/BT-01.md) | Ship the licences | grep proves no "MIT" claim is left; about-panel text still needs one human look |
| [BT-15](issues/BT-15.md) | Remove the Ice-derived drag engine | ~1,000 lines gone, gates pass, reveal and auto-collapse unchanged on the live bar |
| [BT-03](issues/BT-03.md) | Screen recording: ask at the right moment | Granted and revoked live: banner, General state and the item names follow on activation, no reopening |
| [BT-06](issues/BT-06.md) | Tracer bullet: real icons | Confirmed live: every item in the list carries its own icon, 1.25 s per pass, 0 % CPU while the window sits open |

### Dropped
| ID | Title | Why |
| --- | --- | --- |
| [BT-13](issues/BT-13.md) | Accessibility names for the tabs | The problem never existed — `.tabItem` already sets `AXDescription` |
| [BT-05](issues/BT-05.md) | Starting-point proposal | BarT cannot move items any more |
| [BT-08](issues/BT-08.md) | Context menu on icons | The items view is read-only |
| [BT-09](issues/BT-09.md) | Drag icons between sections | Would need the capability BT-15 removes |
| [BT-10](issues/BT-10.md) | Rework "could not be positioned" | The failure disappears with the engine |

## Dependency graph

```mermaid
graph LR
  BT15[BT-15 Remove drag engine ✅] --> BT03[BT-03 Screen recording ✅]
  BT15 --> BT04[BT-04 Welcome]
  BT15 --> BT16[BT-16 Teach ⌘-drag]
  BT04 --> BT16
  BT03 --> BT06[BT-06 Icons tracer ✅]
  BT15 --> BT06
  BT06 --> BT07[BT-07 Grid, read-only]
  BT07 --> BT02[BT-02 README]
  BT16 --> BT02
  BT11[BT-11 Shortcut]
  BT01[BT-01 Licences ✅] --> BT02
  BT02 --> BT14[BT-14 Publish]
  BT07 --> BT14
  BT16 --> BT14
  BT11 --> BT14
  BT12[BT-12 Auto-collapse ✅] --> BT14
```

## How this is cut

Every issue is a **vertical slice**: it crosses whatever layers it needs and ends in something
observable in the running app. Hence the "Visible result" line in each — an issue that cannot state
one is cut wrong.

[BT-15](issues/BT-15.md) is the exception that proves it: its visible result is *nothing changes*.
It deletes machinery the user never saw, and the proof of success is that reveal and collapse
behave exactly as before. That is why it is one removing commit and nothing else — revertible in a
single step if the assertion engine later wants pieces back.

The tracer-bullet idea survives in [BT-06](issues/BT-06.md): capture one icon per item and draw it
in the list that already exists, before building the grid on top of it. It answers the riskiest
unknown (a new permission, an unproven API, unknown cost) first rather than last.

## Parallelism

What is left of BarT is a welcome window, an explanation and a keyboard shortcut — which is why
almost every open issue is 👤 HITL. Only a person can judge whether an explanation lands or a
shortcut feels right. [BT-07](issues/BT-07.md) is the exception and can run alongside any of them:
the capture path it builds on is proven and measured.

[BT-06](issues/BT-06.md) settled the ceiling that [BT-03](issues/BT-03.md) measured: nine of
twenty-one items carry no window title at all, and the icon is what tells those nine apart. It also
settled how they have to be drawn — the menu bar is translucent, so under a dark desktop picture
macOS renders every glyph white, and an icon shown on a plain window background is invisible. The
grid in BT-07 inherits that chip, not just the images.
