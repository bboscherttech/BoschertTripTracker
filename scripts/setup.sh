#!/bin/zsh
set -eu
cd "${0:A:h}/.."
if ! command -v python3.13 >/dev/null 2>&1; then
  print -u2 "Python 3.13 is needed only for development. Install it, then run this setup again."
  exit 1
fi
python3.13 -m venv .venv
.venv/bin/python -m pip install -r requirements-lock.txt
print "Ready. Open BoschertTripTracker.xcodeproj and run the Boschert Trip Tracker scheme on My Mac."
