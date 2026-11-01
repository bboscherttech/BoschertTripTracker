#!/bin/zsh
set -eu
cd "${0:A:h}/.."
if [[ ! -x .venv/bin/python ]]; then
  print -u2 "Development dependencies are missing. Run: zsh scripts/setup.sh"
  exit 1
fi
mkdir -p .build
export PYINSTALLER_CONFIG_DIR="$PWD/.build/pyinstaller-cache"
TRIPTRACKER_FINGERPRINT=$(/usr/bin/shasum -a 256 probe.py maintenance.py flights.py requirements-lock.txt scripts/prepare-worker.sh)
if [[ -x .build/worker-dist/triptracker-worker/triptracker-worker && -f .build/worker-inputs.txt ]] && \
   [[ "$(cat .build/worker-inputs.txt)" == "$TRIPTRACKER_FINGERPRINT" ]]; then
  print "Flight helper is current."
  exit 0
fi
.venv/bin/python -m PyInstaller --noconfirm --clean --onedir \
  --name triptracker-worker --distpath .build/worker-dist --workpath .build/pyinstaller \
  --specpath .build --copy-metadata fast-flights probe.py
print -r -- "$TRIPTRACKER_FINGERPRINT" > .build/worker-inputs.txt
