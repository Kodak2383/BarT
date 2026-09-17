# Coding standards

Distilled from the existing code, not invented for this file. Provided to a coding agent as
*optional context it may pull*; the reviewer gets it *forced into the prompt* (see
[REVIEW-PROMPT.md](REVIEW-PROMPT.md)).

## Language and layout
- Swift 6, strict concurrency. UI and controller types are `@MainActor`.
- Tabs for indentation, never spaces.
- Everything in the app is English: identifiers, UI strings, debug output, comments.
- macOS 26 deployment target. No `@available` gymnastics — if something needs a version check,
  ask first.

## Comments earn their place
- A comment says **why**, never **what**. `// increment counter` is noise; "Observed live: two
  simultaneous drags on the same item destroyed each other" is the standard.
- Measured numbers belong in the comment: "76 entries for 22 real items, measured" beats "grows
  over time".
- A deliberate simplification with a known ceiling is marked `ponytail:` and names the upgrade
  path. Example in `GlobalHotKey`: hard-wired combination, "make it configurable once somebody
  trips over the assignment".

## Structure
- **No abstraction for a single implementation.** There is exactly one hide engine and therefore
  no protocol. Do not introduce one "for later" — that decision is recorded in the PRD.
- Deletion beats addition. The shortest diff that actually solves the problem wins.
- No new dependencies. Standard library and system frameworks only.
- Fewest files possible; a new file needs a reason a reviewer would accept.

## Tests
- There is no test framework and none is to be added. Logic that can be checked in isolation is
  checked in a `runSelfTest()` extension with plain `assert`/`check` calls — see
  `MenuBarLayout.runSelfTest()` and `OscillationGuard.runSelfTest()`. Both run via
  `BART_SELF_TEST=1` and from the ⌥-only debug menu.
- Anything that cannot be checked that way (UI, TCC, drags, ScreenCaptureKit) gets a verification
  script under `scripts/verify/<ISSUE>.sh` instead. Write it **before** the implementation and
  watch it fail — that is this project's red step.
- A self-test that passes without the code is worthless. A verification script that reads the
  code instead of the running app is worthless too.

## Errors and users
- Error text is aimed at the person using the app, not at the developer. Existing example:
  "'Stats' could not be positioned reliably — most likely an item sitting right next to it comes
  along on every move."
- Failing silently is not an option, and neither is a message with no way out.

## Provenance and licence
- BarT is GPL-3.0 because it contains code from Ice (GPL-3.0). Any code taken from elsewhere is
  marked in place with file and commit, and listed in `THIRD-PARTY-LICENSES.md`.
- Never claim a licence without checking it. The MIT claim in this repo survived for weeks and was
  wrong.
