#!/bin/bash
# tags_check.sh [live] : headless check of the tag / sort features of the fork-tags build. No window (SDL dummy video),
# no audio (dummy driver), throwaway data dir + score DB copy. Default: scratch copies of a few songs, tagged in the
# copy by apply_tags.py. "live": read-only scan of the live library (after the real tag pass).
set -uo pipefail
REPO="$HOME/src/USDX-fork-tags"
LIVE="$HOME/Library/Application Support/UltraStarDeluxe2026.2.0"
BIN="$REPO/UltraStar Deluxe.app/Contents/MacOS/ultrastardx"
NAME="UltraStarDeluxe-tags-check-$$"
DATA="$HOME/Library/Application Support/$NAME"
WORK="$(mktemp -d -t usdx-tags)"
trap 'rm -rf "$WORK" "$DATA"' EXIT
mkdir -p "$DATA"
cp "$LIVE/Ultrastar.db" "$DATA/Ultrastar.db"       # copy: plays for "Most played", never the live DB
if [ "${1:-}" = live ]; then
  SONGS="$LIVE/songs"
else
  SONGS="$WORK/songs"
  for d in "3OH!3 ft. Katy Perry - Starstrukk (Duett)" "_NEW_AI/¥\$, Kanye West - BURN (AI)" "_NEW_AI/2NE1 - Do You Love Me (AI)" \
           "ABBA - Dancing Queen" "Backstreet Boys - I Wan't it that Way" "Travis Scott - Drugs You Should Try It" \
           "Britney Spears - Baby One More Time" "Amy Winehouse - Back To Black"; do
    S="$LIVE/songs/$d"; [ -d "$S" ] || { S=$(ls -d "$LIVE/songs/$d"* "$LIVE/songs/"*/"$d"* 2>/dev/null | head -1); }
    [ -d "$S" ] || { echo "skip (not found): $d"; continue; }
    mkdir -p "$SONGS/$d"
    find "$S" -maxdepth 1 \( -name '*.txt' -o -name '*.mp3' -o -name '*.m4a' -o -name '*.ogg' -o -name '*.reading' \) -exec cp -p {} "$SONGS/$d/" \;
  done
  USDX_SONGS="$SONGS" /usr/bin/python3 "$HOME/.local/share/usdx_ai/forktags/apply_tags.py" --apply >/dev/null
fi
printf '[Directories]\nSongDir1=%s\n[Game]\nTabs=Off\n' "$SONGS" > "$DATA/config.ini"
SDL_MAC_BACKGROUND_APP=1 SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy USDX_DATA_NAME="$NAME" LONGQ_TAGS_DRYRUN=1 \
  nice -n 15 "$BIN" 2>&1 | grep -a -E '^(PASS|FAIL|SORT|CAT|THREE|LIST|FILTER|entries|dry run)'
exit ${PIPESTATUS[0]}
