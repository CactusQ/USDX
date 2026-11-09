#!/bin/bash
# selftest.sh [song-folder] : run the longq app's scripted self-test (ULongqAutotest) on one song.
#   Windowed, background (no focus grab), game volume 0, Mac output muted first, scratch config,
#   scratch score DB, song library untouched. Prints the AUTOTEST log lines and screenshot paths.
# default song: _NEW_AI/f5ve - UFO (AI) from the stock app's library
set -uo pipefail
APP="${APP:-/Applications/UltraStar Deluxe longq.app}"
LIVE_SONGS="${LIVE_SONGS:-$HOME/Library/Application Support/UltraStarDeluxe2026.2.0/songs}"
SONG_DIR="${1:-$LIVE_SONGS/_NEW_AI/f5ve - UFO (AI)}"
DATA_DIR="$HOME/Library/Application Support/UltraStar Deluxe longq"
LOG_DIR="$HOME/Library/Logs/UltraStar Deluxe longq"
WORK="$(mktemp -d -t usdx-selftest)"

osascript -e 'set volume output muted true' >/dev/null 2>&1 || true   # never unmuted here

mkdir -p "$WORK/songs" && ln -s "$SONG_DIR" "$WORK/songs/$(basename "$SONG_DIR")"
python3 - "$DATA_DIR/config.ini" "$WORK/config.ini" <<'PY'
import sys, re
src, dst = sys.argv[1:]
try: t = open(src, encoding="utf-8", errors="replace").read()
except FileNotFoundError: t = ""
def put(t, sec, key, val):
    if re.search(rf"(?m)^\[{sec}\]", t) is None: t += f"\n[{sec}]\n"
    if re.search(rf"(?m)^{key}=", t): return re.sub(rf"(?m)^{key}=.*$", f"{key}={val}", t)
    return re.sub(rf"(?m)^\[{sec}\]\s*$", f"[{sec}]\n{key}={val}", t, count=1)
t = re.sub(r"(?ms)^\[Record\].*?(?=^\[|\Z)", "", t)          # no mic channels assigned
for sec, k, v in [("Directories", "SongDir1", ""), ("Sound", "BackgroundMusic", "Off"),
                  ("Sound", "PreviewVolume", "0"), ("Lyrics", "ReadingLine", "Above"),
                  ("Graphics", "FullScreen", "Off"), ("Game", "Tabs", "Off")]:
    t = put(t, sec, k, v)
open(dst, "w", encoding="utf-8").write(t)
PY
SHOTS="$DATA_DIR/screenshots"; mkdir -p "$SHOTS"; touch "$WORK/stamp"
[ -f "$LOG_DIR/Error.log" ] && mv "$LOG_DIR/Error.log" "$LOG_DIR/Error.prev.log"

SDL_MAC_BACKGROUND_APP=1 LONGQ_AUTOTEST=1 LONGQ_AUTOTEST_SONG="${LONGQ_AUTOTEST_SONG:-}" \
  "$APP/Contents/MacOS/ultrastardx" -window -resolution "${RES:-1280x720}" \
  -songpath "$WORK/songs" -configfile "$WORK/config.ini" -scorefile "$WORK/scores.db" \
  > "$WORK/stdout.log" 2>&1 &
PID=$!
for _ in $(seq 1 180); do kill -0 $PID 2>/dev/null || break; sleep 1; done
if kill -0 $PID 2>/dev/null; then echo "selftest: TIMEOUT, killing"; kill $PID; RC=124; else wait $PID; RC=$?; fi

echo "selftest: exit=$RC  work=$WORK"
grep -h 'AUTOTEST\|reading' "$LOG_DIR/Error.log" "$WORK/stdout.log" 2>/dev/null | sed 's/^/  /'
echo "screenshots:"; find "$SHOTS" -newer "$WORK/stamp" -type f | sort | sed 's/^/  /'
exit $RC
