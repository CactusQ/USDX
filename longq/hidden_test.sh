#!/bin/bash
# hidden_test.sh SONG_DIR [more song dirs...] : run the scripted self-test (ULongqAutotest) on the
# BUILT bundle in this repo with an INVISIBLE window, safe while the operator plays:
#   LONGQ_HIDDEN=1 (window never shown), SDL_MAC_BACKGROUND_APP=1 (no Dock icon, no focus),
#   SDL_AUDIODRIVER=dummy (nothing reaches the speakers, the Mac volume is not touched),
#   throwaway data dir + log dir (USDX_DATA_NAME), scratch config/scores, songs symlinked read-only.
# Env: RES (default 960x540), LONGQ_AUTOTEST_PLAYERS (2 = duet both tracks), APP, TIMEOUT (s, 240).
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP="${APP:-$REPO/UltraStar Deluxe.app}"
[ $# -ge 1 ] || { sed -n 2,7p "$0"; exit 1; }
LIVE_CFG="$HOME/Library/Application Support/UltraStarDeluxe2026.2.0/config.ini"
RC_ALL=0
for SONG_DIR in "$@"; do
  NAME="UltraStarDeluxe-hidden-test-$$"
  DATA="$HOME/Library/Application Support/$NAME"; LOGD="$HOME/Library/Logs/$NAME"
  WORK="$(mktemp -d -t usdx-hidden)"
  mkdir -p "$WORK/songs" "$DATA" && ln -s "$SONG_DIR" "$WORK/songs/$(basename "$SONG_DIR")"
  python3 - "$LIVE_CFG" "$WORK/config.ini" <<'PY'
import sys, re, os
src, dst = sys.argv[1:]
try: t = open(src, encoding="utf-8", errors="replace").read()   # read-only copy of the live settings
except OSError: t = ""
def put(t, sec, key, val):
    if not re.search(r"(?m)^\[%s\]" % sec, t): t += "\n[%s]\n" % sec
    if re.search(r"(?ms)^\[%s\].*?^%s=" % (sec, key), t):
        return re.sub(r"(?ms)(^\[%s\].*?^)%s=[^\n]*" % (sec, key), r"\g<1>%s=%s" % (key, val), t, count=1)
    return re.sub(r"(?m)^\[%s\]\n" % sec, "[%s]\n%s=%s\n" % (sec, key, val), t, count=1)
t = re.sub(r"(?ms)^\[Record\].*?(?=^\[|\Z)", "", t)          # no mic channels assigned
for sec, k, v in [("Directories", "SongDir1", ""), ("Sound", "BackgroundMusic", "Off"),
                  ("Sound", "PreviewVolume", "0"), ("Game", "Tabs", "Off"), ("Graphics", "FullScreen", "Off")]:
    t = put(t, sec, k, v)
if os.environ.get("VIS"): t = put(t, "Graphics", "Visualization", os.environ["VIS"])
open(dst, "w", encoding="utf-8").write(t)
PY
  echo "== $(basename "$SONG_DIR")"
  LONGQ_HIDDEN=1 SDL_MAC_BACKGROUND_APP=1 SDL_AUDIODRIVER=dummy USDX_DATA_NAME="$NAME" \
  LONGQ_AUTOTEST=1 LONGQ_AUTOTEST_SONG="${LONGQ_AUTOTEST_SONG:-}" \
    nice -n 15 "$APP/Contents/MacOS/ultrastardx" -window -resolution "${RES:-960x540}" \
    -songpath "$WORK/songs" -configfile "$WORK/config.ini" -scorefile "$WORK/scores.db" \
    > "$WORK/stdout.log" 2>&1 &
  PID=$!
  for _ in $(seq 1 "${TIMEOUT:-240}"); do kill -0 $PID 2>/dev/null || break; sleep 1; done
  if kill -0 $PID 2>/dev/null; then echo "TIMEOUT, killing"; kill $PID; RC=124; else wait $PID; RC=$?; fi
  { [ -s "$LOGD/Error.log" ] && cat "$LOGD/Error.log" || cat "$WORK/stdout.log"; } 2>/dev/null | grep -a 'AUTOTEST\|cover viz' | sed 's/^.*AUTOTEST /  /'
  echo "  exit=$RC"
  [ "$RC" = 0 ] || RC_ALL=$RC
  rm -rf "$WORK" "$DATA" "$LOGD"
done
exit $RC_ALL
