#!/bin/bash
# reading_frames.sh OUT_DIR TAG CHART.txt [Section.Key=Value ...] : render the scripted self-test
# (ULongqAutotest: 3 screenshots on sung lines) of ONE chart with an INVISIBLE window, no audio,
# scratch config/data/scores, and copy the screenshots to OUT_DIR/TAG_N.png. Night only (01-09).
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP="${APP:-$REPO/UltraStar Deluxe.app}"
[ $# -ge 3 ] || { sed -n 2,5p "$0"; exit 1; }
OUT="$1"; TAG="$2"; CHART="$3"; shift 3
H=$(date +%H); H=${H#0}
if [ "${USDX_GUI_NOW:-}" != 1 ] && [ "$H" -ge 9 ]; then
  echo "reading_frames.sh: refused at $(date +%H:%M); runs only 01:00-09:00 (operator rule 2026-11-10)" >&2; exit 75
fi
mkdir -p "$OUT"
NAME="UltraStarDeluxe-frames-$$"
DATA="$HOME/Library/Application Support/$NAME"; LOGD="$HOME/Library/Logs/$NAME"
WORK="$(mktemp -d -t usdx-frames)"
SD="$(dirname "$CHART")"; SONG="$WORK/songs/$(basename "$SD")"
mkdir -p "$SONG" "$DATA"
# only this chart (+ its .reading) and the media: no sibling charts, so the autotest picks it
for f in "$SD"/*; do case "$f" in *.txt|*.reading|*.sco) ;; *) ln -s "$f" "$SONG/";; esac; done
ln -s "$CHART" "$SONG/"; [ -f "${CHART%.txt}.reading" ] && ln -s "${CHART%.txt}.reading" "$SONG/"
python3 - "$HOME/Library/Application Support/UltraStarDeluxe2026.2.0/config.ini" "$WORK/config.ini" "$@" <<'PY'
import sys, re
src, dst, *kv = sys.argv[1:]
try: t = open(src, encoding="utf-8", errors="replace").read()
except OSError: t = ""
def put(t, sec, key, val):
    if not re.search(r"(?m)^\[%s\]" % sec, t): t += "\n[%s]\n" % sec
    if re.search(r"(?ms)^\[%s\][^\[]*?^%s=" % (sec, key), t):
        return re.sub(r"(?ms)(^\[%s\][^\[]*?^)%s=[^\n]*" % (sec, key), r"\g<1>%s=%s" % (key, val), t, count=1)
    return re.sub(r"(?m)^\[%s\]\n" % sec, "[%s]\n%s=%s\n" % (sec, key, val), t, count=1)
t = re.sub(r"(?ms)^\[Record\].*?(?=^\[|\Z)", "", t)
for sec, k, v in [("Directories", "SongDir1", ""), ("Sound", "BackgroundMusic", "Off"), ("Sound", "PreviewVolume", "0"),
                  ("Game", "Tabs", "Off"), ("Graphics", "FullScreen", "Off"), ("Lyrics", "LyricVersions", "Off")]:
    t = put(t, sec, k, v)
for a in kv:
    sk, v = a.split("=", 1); s, k = sk.split(".", 1); t = put(t, s, k, v)
open(dst, "w", encoding="utf-8").write(t)
PY
LONGQ_HIDDEN=1 SDL_MAC_BACKGROUND_APP=1 SDL_AUDIODRIVER=dummy USDX_DATA_NAME="$NAME" LONGQ_AUTOTEST=1 \
  nice -n "${NICE:-10}" "$APP/Contents/MacOS/ultrastardx" -window -resolution "${RES:-1280x720}" \
  -songpath "$WORK/songs" -configfile "$WORK/config.ini" -scorefile "$WORK/scores.db" > "$WORK/stdout.log" 2>&1 &
PID=$!
for _ in $(seq 1 "${TIMEOUT:-240}"); do kill -0 $PID 2>/dev/null || break; sleep 1; done
if kill -0 $PID 2>/dev/null; then echo "TIMEOUT, killing"; kill $PID; sleep 2; kill -9 $PID 2>/dev/null; RC=124; else wait $PID; RC=$?; fi
{ [ -s "$LOGD/Error.log" ] && cat "$LOGD/Error.log" || cat "$WORK/stdout.log"; } 2>/dev/null | grep -a 'AUTOTEST\|reading' | sed 's/^.*AUTOTEST /  /' | head -20
i=0; for p in $(ls -tr "$DATA"/screenshots/*.jpg 2>/dev/null); do i=$((i+1)); cp "$p" "$OUT/${TAG}_$i.jpg"; done
echo "$TAG: exit=$RC frames=$i"
mv "$WORK" "$OUT/.work_$TAG" 2>/dev/null; mv "$DATA" "$OUT/.data_$TAG" 2>/dev/null; mv "$LOGD" "$OUT/.log_$TAG" 2>/dev/null
exit $RC
