#!/bin/sh
# Run by each app target's "Stamp Commit" build phase: records the commit the app was built from
# in its built Info.plist (SetPilotCommit), with "-dirty" if there were uncommitted changes.
# Settings and About show it. Without git or a repository, the key is left out.
set -eu
plist="$TARGET_BUILD_DIR/$INFOPLIST_PATH"
buddy=/usr/libexec/PlistBuddy
"$buddy" -c "Delete :SetPilotCommit" "$plist" >/dev/null 2>&1 || true
commit=$(git -C "$SRCROOT" describe --always --dirty --abbrev=8 --exclude='*' 2>/dev/null) || exit 0
"$buddy" -c "Add :SetPilotCommit string $commit" "$plist"
