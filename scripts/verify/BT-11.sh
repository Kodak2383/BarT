#!/bin/zsh
# BT-11 — the recorded shortcut has to be the one that actually gets registered.
#
# Writes a combination into BarT's own defaults exactly the way the recorder does (⌃⌥⌘K),
# starts the app and reads back which combination it registered. That covers the half of the
# issue no self-test can reach: persistence → Carbon. The recording gesture itself needs a
# person and is the acceptance step in the issue.
#
# Carbon masks: controlKey 4096 | optionKey 2048 | cmdKey 256 = 6400. kVK_ANSI_K = 40.
set -uo pipefail
cd "${0:a:h}/../.."
DOMAIN=de.andreduhme.BarT
APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/BarT-*/Build/Products/Debug/BarT.app 2>/dev/null | head -1)
[[ -n "$APP" ]] || { print "no built app found"; exit 1 }

# Whatever the maintainer has set stays set — this script runs on their live machine.
OLD_CODE=$(defaults read $DOMAIN hotKeyCode 2>/dev/null || print -- "-")
OLD_MODS=$(defaults read $DOMAIN hotKeyModifiers 2>/dev/null || print -- "-")
OLD_NAME=$(defaults read $DOMAIN hotKeyName 2>/dev/null || print -- "-")
restore() {
	for key value in hotKeyCode $OLD_CODE hotKeyModifiers $OLD_MODS hotKeyName $OLD_NAME; do
		if [[ "$value" == "-" ]]; then
			defaults delete $DOMAIN $key 2>/dev/null
		elif [[ "$key" == hotKeyName ]]; then
			defaults write $DOMAIN $key -string "$value"
		else
			defaults write $DOMAIN $key -int "$value"
		fi
	done
}
trap restore EXIT

defaults write $DOMAIN hotKeyCode -int 40
defaults write $DOMAIN hotKeyModifiers -int 6400
defaults write $DOMAIN hotKeyName -string K

OUT=$(BART_SELF_TEST=1 timeout 30 "$APP/Contents/MacOS/BarT" 2>&1 | grep -E 'Hotkey|Shortcut self-test')
pkill -x BarT 2>/dev/null
print -r -- "$OUT"

print -r -- "$OUT" | grep -q 'Hotkey ⌃⌥⌘K: registered' || { print "the stored combination was not the registered one"; exit 1 }
print -r -- "$OUT" | grep -q 'Shortcut self-test FAILED' && { print "shortcut self-test failed"; exit 1 }
print "BT-11 verified: ⌃⌥⌘K survived the launch and was registered"
