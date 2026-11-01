#!/bin/zsh
set -eu
cd "${0:A:h}"
mkdir -p .build dist
zsh scripts/prepare-worker.sh
# Stage outside synced folders so Finder metadata cannot interfere with signing.
TRIPTRACKER_STAGE=$(mktemp -d /private/tmp/boschert-trip-tracker.XXXXXX)
TRIPTRACKER_APP="$TRIPTRACKER_STAGE/Boschert Trip Tracker.app"
mkdir -p "$TRIPTRACKER_APP/Contents/MacOS" "$TRIPTRACKER_APP/Contents/Resources"
/usr/bin/swiftc -parse-as-library -O -target arm64-apple-macosx14.0 \
  -module-cache-path "$PWD/.build/module-cache" BoschertTripTrackerApp.swift TripCore.swift HealthStatus.swift TrackerStore.swift FlightSearchView.swift TrackedTripView.swift TrackerSettingsView.swift \
  -o "$TRIPTRACKER_APP/Contents/MacOS/BoschertTripTracker"
/usr/bin/swiftc -O -target arm64-apple-macosx14.0 -module-cache-path "$PWD/.build/module-cache" \
  BuildIcon.swift -o .build/build-icon
.build/build-icon Assets/BoschertTechnologiesMark.png .build/AppIcon.iconset
/usr/bin/ditto --norsrc --noextattr Assets "$TRIPTRACKER_APP/Contents/Resources"
/usr/bin/iconutil -c icns .build/AppIcon.iconset -o "$TRIPTRACKER_APP/Contents/Resources/AppIcon.icns"
/usr/bin/ditto --norsrc --noextattr .build/worker-dist/triptracker-worker "$TRIPTRACKER_APP/Contents/Resources/worker"
/usr/bin/ditto Configuration/Info.plist "$TRIPTRACKER_APP/Contents/Info.plist"
# Remove Finder's display metadata from this generated bundle only. Preserve
# quarantine and provenance attributes; do not change Gatekeeper settings.
/usr/bin/xattr -dr com.apple.FinderInfo "$TRIPTRACKER_APP" 2>/dev/null || true
/usr/bin/codesign --force --deep --sign - "$TRIPTRACKER_APP"
/usr/bin/codesign --verify --deep --strict "$TRIPTRACKER_APP"
/usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$TRIPTRACKER_APP" "$PWD/dist/Boschert Trip Tracker.zip"
print -r -- "$TRIPTRACKER_APP" > .build/app-path.txt
print "Built: $TRIPTRACKER_APP"
print "Download: $PWD/dist/Boschert Trip Tracker.zip"
