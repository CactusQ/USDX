#!/bin/bash
# versions_check.sh [SONGS_DIR] : headless checks for the lyric-version picker. No window, no audio,
# never touches the live config or songs (read-only scan of the live library for the dry-run table).
#  1. lvtest: unit asserts for ULongqVersionKey + a grouping table of SONGS_DIR (default: live library)
#  2. the built app with LONGQ_VERSIONS_DRYRUN=1, SDL_VIDEODRIVER=dummy and a throwaway data dir whose
#     config points at a scratch copy of 3 songs (11 charts); prints PASS/FAIL, exits non-zero on FAIL.
# Run after `make` + bundle (rebuild.sh with NO_INSTALL=1, or the steps in longq/README.md).
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LIVE="$HOME/Library/Application Support/UltraStarDeluxe2026.2.0/songs"
SONGS="${1:-$LIVE}"
WORK="$(mktemp -d -t usdx-versions)"
NAME="UltraStarDeluxe-versions-check-$$"
DATA="$HOME/Library/Application Support/$NAME"
trap 'rm -rf "$WORK" "$DATA"' EXIT
# shellcheck disable=SC1091
source "$REPO/longq/env.sh"

echo "== 1. unit + grouping table ($SONGS)"
(cd "$REPO/longq/lvtest" && nice -n 15 fpc -Paarch64 -Fu../../src/base -FE"$WORK" -FU"$WORK" lvtest.pas >/dev/null)
"$WORK/lvtest" "$SONGS" > "$WORK/table.txt"
grep -a -E '^(FAIL|unit fails|charts=)' "$WORK/table.txt"

echo "== 2. game dry run (headless)"
T="$WORK/songs"
mkdir -p "$T/_NEW_AI"
for d in "_NEW_AI/f5ve - UFO" "_NEW_AI/f5ve - UFO (AI)" "_NEW_AI/f5ve - UFO (AI romaji)" "_NEW_AI/f5ve - UFO (AI kanji)" \
         "_NEW_AI/BLACKPINK - As If It's Your Last (AI)" "_NEW_AI/BLACKPINK - As If It's Your Last (AI romaji)" \
         "BLACKPINK - As If Its Your Last" "Lady Gaga, Bradley Cooper - Shallow" "_NEW_AI/Nelly - Hot In Herre (AI)"; do
  mkdir -p "$T/$d"
  find "$LIVE/$d" -maxdepth 1 \( -name '*.txt' -o -name '*.mp3' -o -name '*.reading' \) -exec cp -p {} "$T/$d/" \;
done
mkdir -p "$DATA"
printf '[Directories]\nSongDir1=%s\n' "$T" > "$DATA/config.ini"
BIN="$REPO/UltraStar Deluxe.app/Contents/MacOS/ultrastardx"
SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy USDX_DATA_NAME="$NAME" LONGQ_VERSIONS_DRYRUN=1 \
  nice -n 15 "$BIN" 2>&1 | grep -a -E '^(PASS|FAIL|ENTRY|   |charts=|picked|dry run)'
exit "${PIPESTATUS[0]}"
