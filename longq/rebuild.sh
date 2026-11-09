#!/bin/bash
# rebuild.sh <ref> : rebase our `longq` patches onto an upstream ref, build arm64, install
#                    "/Applications/UltraStar Deluxe longq.app" (the stock app is never touched).
#   ref = master | latest-release | <tag, e.g. v2026.11.0> | <any upstream sha>
# Env: PROMOTED=1 (also refresh /Applications/UltraStarDeluxe.app, the promoted install, keeping its
#      longq_datadir)  NO_INSTALL=1 (build only)  SKIP_REBASE=1 (build current checkout)  JOBS=N
# Exit: 0 ok, 2 rebase conflict (rebase aborted, branch untouched), 1 other failure.
# Long runs: python3 ~/scripts/detach_run.py --name usdx-build -- ~/src/USDX/longq/rebuild.sh latest-release
set -uo pipefail

# The rebase rewrites this file; run from a private copy.
if [ -z "${_LONGQ_REEXEC:-}" ]; then
  tmp="$(mktemp -t usdx-rebuild)"; cp "$0" "$tmp"
  export _LONGQ_REEXEC=1 _LONGQ_REPO="$(cd "$(dirname "$0")/.." && pwd)"
  # build natively on Apple silicon even when the caller's shell runs under Rosetta
  if [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] && [ "$(uname -m)" != arm64 ]; then
    exec arch -arm64 /bin/bash "$tmp" "$@"
  fi
  exec /bin/bash "$tmp" "$@"
fi

REF="${1:-}"; [ -n "$REF" ] || { sed -n 2,8p "$0"; exit 1; }
REPO="$_LONGQ_REPO"; cd "$REPO"
APP_DST="${APP_DST:-/Applications/UltraStar Deluxe longq.app}"
DATA_DIR="$HOME/Library/Application Support/UltraStar Deluxe longq"
LIVE_DATA="${LIVE_DATA:-$HOME/Library/Application Support/UltraStarDeluxe2026.2.0}"
LOG="$REPO/longq/BUILD_LOG.md"
BUILD_OUT="$REPO/longq/.last-build.log"
UPSTREAM_SHA="?"; LONGQ_SHA="?"

log_result() { # result note
  [ -f "$LOG" ] || printf '# USDX longq build log\n\n| when (UTC) | ref | upstream sha | longq sha | result | note |\n|---|---|---|---|---|---|\n' > "$LOG"
  printf '| %s | %s | %s | %s | %s | %s |\n' "$(date -u +%FT%TZ)" "$REF" "${UPSTREAM_SHA:0:10}" "${LONGQ_SHA:0:10}" "$1" "${2:-}" >> "$LOG"
}
die() { echo "rebuild: $1" >&2; log_result FAIL "$1"; exit 1; }

# ---- jobs: respect the cpu governor (e.g. "LIMIT 2" by day) ---------------
if [ -z "${JOBS:-}" ]; then
  JOBS="$(grep -Eo '[0-9]+' "$HOME/.config/cpu-governor/mode" 2>/dev/null | head -1)"; JOBS="${JOBS:-2}"
fi

# ---- 1. resolve + rebase ---------------------------------------------------
git fetch -q upstream --tags || die "git fetch upstream failed"
case "$REF" in
  latest-release) REF_RESOLVED="$(gh api repos/UltraStar-Deluxe/USDX/releases/latest --jq .tag_name)" || die "cannot resolve latest release" ;;
  master|main) REF_RESOLVED="upstream/$REF" ;;
  *) REF_RESOLVED="$REF" ;;
esac
UPSTREAM_SHA="$(git rev-parse --verify -q "$REF_RESOLVED^{commit}")" || die "unknown ref $REF_RESOLVED"
echo "rebuild: ref=$REF -> $REF_RESOLVED ($UPSTREAM_SHA)"

if [ -z "${SKIP_REBASE:-}" ]; then
  [ "$(git rev-parse --abbrev-ref HEAD)" = longq ] || git checkout -q longq || die "cannot checkout longq"
  [ -z "$(git status --porcelain --untracked-files=no)" ] || die "worktree has uncommitted changes"
  # our patches = commits between the upstream base and longq; they must all be "longq:" commits
  BASE="$(git merge-base longq upstream/master)"
  NONOURS="$(git log --format='%h %s' "$BASE..longq" | grep -v '^[0-9a-f]* longq:' || true)"
  [ -z "$NONOURS" ] || die "non-longq commits on branch: $(echo "$NONOURS" | head -1)"
  if ! git rebase -q --onto "$UPSTREAM_SHA" "$BASE" longq; then
    BAD="$(git log -1 --format='%h %s' REBASE_HEAD 2>/dev/null || echo '?')"
    echo "rebuild: CONFLICT while applying: $BAD" >&2
    git status --short | grep -E '^(UU|AA|DU|UD) ' >&2
    git rebase --abort
    log_result CONFLICT "$BAD"
    exit 2
  fi
fi
LONGQ_SHA="$(git rev-parse HEAD)"
git log --oneline "$UPSTREAM_SHA..HEAD"

# ---- 2. toolchain + dependency kit ----------------------------------------
TC="${USDX_TOOLCHAIN:-$HOME/src/usdx-toolchain}"
[ -x "$TC/fpc/bin/fpc" ] || die "FPC missing at $TC/fpc (see longq/README.md: toolchain)"
KIT_TAG="$(git describe --tags --abbrev=0 --match 'v2*' "$UPSTREAM_SHA" 2>/dev/null)"
"$REPO/longq/kit.sh" "$KIT_TAG" >/dev/null 2>&1 || { echo "rebuild: no ARM kit for $KIT_TAG, using newest kit"; KIT_TAG=""; }
export KIT_TAG
# shellcheck disable=SC1091
source "$REPO/longq/env.sh"
echo "rebuild: kit=$KIT jobs=$JOBS"

# ---- 3. build ---------------------------------------------------------------
{
  nice -n 15 ./autogen.sh && nice -n 15 ./configure --without-opencv && nice -n 15 make clean && nice -n 15 make -j"$JOBS" "PPC=fpc -Paarch64"
} > "$BUILD_OUT" 2>&1 || { grep -E 'Error|Fatal' "$BUILD_OUT" | head -5 >&2; die "build failed (see longq/.last-build.log)"; }
file game/ultrastardx | grep -q arm64 || die "binary is not arm64"

# ---- 4. bundle --------------------------------------------------------------
rm -rf "UltraStar Deluxe.app"
nice -n 15 make macos-app >> "$BUILD_OUT" 2>&1 || die "make macos-app failed"
B="UltraStar Deluxe.app/Contents"
cp -f "$KIT"/lib/*.[0-9]*.dylib "$KIT"/lib/libSDL3.dylib "$B/MacOS/" 2>/dev/null
for l in $(otool -L "$B/MacOS/ultrastardx" | awk '/@executable_path/{print $1}' | sed 's|@executable_path/||'); do
  [ -f "$B/MacOS/$l" ] || die "missing dylib $l in kit"
done
PB=/usr/libexec/PlistBuddy
$PB -c "Set :CFBundleIdentifier org.ultrastardeluxe.ultrastardeluxe.longq" "$B/Info.plist"
$PB -c "Set :CFBundleName UltraStar Deluxe longq" "$B/Info.plist"
$PB -c "Set :CFBundleDisplayName UltraStar Deluxe longq" "$B/Info.plist"
$PB -c "Set :CFBundleGetInfoString longq build ${LONGQ_SHA:0:10} on ${UPSTREAM_SHA:0:10}" "$B/Info.plist"
codesign --force --deep --sign - "UltraStar Deluxe.app" >> "$BUILD_OUT" 2>&1 || die "codesign failed"

# ---- 5. install (separate app + separate data dir) --------------------------
if [ -z "${NO_INSTALL:-}" ]; then
  pgrep -f "$APP_DST/Contents/MacOS/ultrastardx" >/dev/null && die "longq app is running; quit it first"
  case "$APP_DST" in *longq*.app) ;; *) die "refusing to install over $APP_DST" ;; esac
  rm -rf "$APP_DST.new" && cp -R "UltraStar Deluxe.app" "$APP_DST.new" && rm -rf "$APP_DST" && mv "$APP_DST.new" "$APP_DST" || die "install failed"
  if [ "${PROMOTED:-0}" = 1 ]; then
    P=/Applications/UltraStarDeluxe.app
    [ -s "$P/Contents/MacOS/longq_datadir" ] || die "$P is not a promoted longq install"
    pgrep -x ultrastardx >/dev/null && die "UltraStar is running; quit it first"
    D="$(cat "$P/Contents/MacOS/longq_datadir")"
    rm -rf "$P.new" && cp -R "UltraStar Deluxe.app" "$P.new" && printf '%s\n' "$D" > "$P.new/Contents/MacOS/longq_datadir" \
      && codesign --force --deep --sign - "$P.new" >/dev/null 2>&1 && rm -rf "$P" && mv "$P.new" "$P" || die "promoted install failed"
  fi
  # first run: seed our own config from a COPY of the stock config, songs read from the stock library
  if [ ! -f "$DATA_DIR/config.ini" ] && [ -f "$LIVE_DATA/config.ini" ]; then
    mkdir -p "$DATA_DIR"
    python3 - "$LIVE_DATA/config.ini" "$DATA_DIR/config.ini" "$LIVE_DATA/songs" <<'PY'
import sys, re
src, dst, songs = sys.argv[1:]
t = open(src, encoding="utf-8", errors="replace").read()
t = re.sub(r"(?m)^SongDir1=.*$", "SongDir1=" + songs, t) if re.search(r"(?m)^SongDir1=", t) else t + "\n[Directories]\nSongDir1=" + songs + "\n"
open(dst, "w", encoding="utf-8").write(t)
PY
  fi
fi

log_result PASS "$(git log --format=%s "$UPSTREAM_SHA..HEAD" | wc -l | tr -d ' ') patches, kit ${KIT##*/}"
echo "rebuild: PASS  upstream=${UPSTREAM_SHA:0:10} longq=${LONGQ_SHA:0:10}  -> $APP_DST"
