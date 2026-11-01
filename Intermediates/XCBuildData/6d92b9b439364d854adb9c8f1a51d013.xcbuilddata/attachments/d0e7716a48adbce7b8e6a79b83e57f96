#!/bin/zsh
set -eu
cd "$SRCROOT"
/bin/zsh "$SRCROOT/scripts/prepare-worker.sh"
mkdir -p "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/worker"
/usr/bin/ditto --norsrc --noextattr "$SRCROOT/.build/worker-dist/triptracker-worker" "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/worker"

