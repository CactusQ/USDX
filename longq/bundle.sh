#!/bin/bash
# bundle.sh : turn the current game/ultrastardx into "UltraStar Deluxe.app" in the repo (no install).
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source longq/env.sh
rm -rf "UltraStar Deluxe.app"
nice -n 15 make macos-app > longq/.last-bundle.log 2>&1
B="UltraStar Deluxe.app/Contents"
cp -f "$KIT"/lib/*.[0-9]*.dylib "$KIT"/lib/libSDL3.dylib "$B/MacOS/" 2>/dev/null || true
for l in $(otool -L "$B/MacOS/ultrastardx" | awk '/@executable_path/{print $1}' | sed 's|@executable_path/||'); do
  [ -f "$B/MacOS/$l" ] || { echo "missing dylib $l"; exit 1; }
done
codesign --force --deep --sign - "UltraStar Deluxe.app" >/dev/null 2>&1
echo "bundle: $(pwd)/UltraStar Deluxe.app ($(git rev-parse --short HEAD)$(git diff --quiet || echo +dirty))"
