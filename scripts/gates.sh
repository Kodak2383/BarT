#!/bin/zsh
# Feedback loop for one change: type-check, self-tests, style, and the issue's own verification.
# Exits non-zero on the first failure, with the reason on stdout — that text is what gets handed
# back to the coding agent.
#
# Usage: scripts/gates.sh [ISSUE-ID]
set -uo pipefail
cd "${0:a:h}/.."
ISSUE="${1:-}"
fail() { print -r -- "GATE FAILED: $*"; exit 1; }

# 1. Type-check. The Swift compiler is this project's type checker; there is no separate one.
print "→ build"
BUILD_LOG=$(mktemp)
if ! xcodebuild -project BarT.xcodeproj -scheme BarT -configuration Debug build >"$BUILD_LOG" 2>&1; then
	fail "build\n$(grep -E 'error:' "$BUILD_LOG" | head -20)"
fi
grep -qE 'warning:.*\.swift' "$BUILD_LOG" && print "  (warnings: $(grep -cE 'warning:.*\.swift' "$BUILD_LOG"))"

# 2. Self-tests. Run against the built binary directly — these check pure logic and need no
#    permissions, so inheriting the terminal's TCC state is harmless here.
print "→ self-tests"
APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/BarT-*/Build/Products/Debug/BarT.app 2>/dev/null | head -1)
[[ -n "$APP" ]] || fail "no built app found"
SELF_TEST=$(BART_SELF_TEST=1 timeout 30 "$APP/Contents/MacOS/BarT" 2>&1 | grep -E 'self-test|FAILED')
pkill -x BarT 2>/dev/null
print -r -- "$SELF_TEST" | grep -q FAILED && fail "self-tests\n$SELF_TEST"
print -r -- "  $(print -r -- "$SELF_TEST" | tr '\n' ' ')"

# 3. Style. No linter is installed and none is to be added — these are the two rules that actually
#    get broken: space indentation, and licence claims that were never checked.
print "→ style"
BAD_INDENT=$(grep -rln '^    [^ ]' --include="*.swift" BarT || true)
[[ -z "$BAD_INDENT" ]] || fail "space indentation in:\n$BAD_INDENT"
BAD_LICENCE=$(grep -rn 'MIT' --include="*.swift" BarT || true)
[[ -z "$BAD_LICENCE" ]] || fail "BarT and Ice are GPL-3.0, not MIT:\n$BAD_LICENCE"

# 4. The issue's own verification, if it has one.
if [[ -n "$ISSUE" && -f "scripts/verify/$ISSUE.sh" ]]; then
	print "→ verify $ISSUE"
	zsh "scripts/verify/$ISSUE.sh" || fail "verification for $ISSUE"
elif [[ -n "$ISSUE" ]]; then
	print "→ verify $ISSUE — no script (fine only for pure-logic issues covered by self-tests)"
fi

print "ALL GATES PASSED"
