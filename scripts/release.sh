#!/bin/zsh
# Builds the app the way a download gets it, and zips it.
#
# One script, run both by hand and by the release workflow on a tag, so what gets tested on a clean
# account is then byte-for-byte what ships. Deliberately into ./build rather than the shared
# DerivedData: the artefact's path has to be predictable, and gates.sh owns the other one.
#
# The app is not signed and not notarised (README, "Installing"). `ditto` rather than `zip`
# because a .app is a bundle: zip flattens symlinks and loses extended attributes.
set -euo pipefail
cd "${0:a:h}/.."
# Self-sufficient: the build log is redirected into build/ before anything creates it.
mkdir -p build dist

print "→ project"
xcodegen generate >/dev/null

print "→ build (Release)"
xcodebuild -project BarT.xcodeproj -scheme BarT -configuration Release \
	-derivedDataPath build -destination "platform=macOS" build >build/release.log 2>&1 || {
		print "GATE FAILED: release build"
		grep -E 'error:' build/release.log | head -20
		exit 1
	}

APP="build/Build/Products/Release/BarT.app"
[[ -d "$APP" ]] || { print "no app at $APP"; exit 1 }
VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")

print "→ zip"
ZIP="dist/BarT-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

print ""
print "$ZIP"
print "  version   $VERSION ($(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist"))"
print "  size      $(du -h "$ZIP" | cut -f1)"
print "  sha256    $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
print "  built for $(plutil -extract LSMinimumSystemVersion raw "$APP/Contents/Info.plist" 2>/dev/null || print '(see project.yml)') and up"
