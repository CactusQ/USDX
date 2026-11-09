#!/bin/bash
# kit.sh <release-tag>: build an arm64 "dependency kit" for USDX from upstream's
# own ARM release dmg (dylibs) + Lua headers from github.com/lua/lua.
# No arm64 Homebrew needed. Output: $USDX_TOOLCHAIN/kit/<tag>/{lib,include,pkgconfig}
set -euo pipefail
TAG="${1:?usage: kit.sh <release-tag e.g. v2026.11.0>}"
TC="${USDX_TOOLCHAIN:-$HOME/src/usdx-toolchain}"
KIT="$TC/kit/$TAG"
[ -f "$KIT/.done" ] && { echo "$KIT"; exit 0; }
VER="${TAG#v}"
DL="$TC/dl"; mkdir -p "$DL" "$KIT/lib" "$KIT/include" "$KIT/pkgconfig"
DMG="$DL/UltraStarDeluxe-mac-ARM-$VER.dmg"
[ -f "$DMG" ] || gh release download "$TAG" -R UltraStar-Deluxe/USDX -p "UltraStarDeluxe-mac-ARM-$VER.dmg" -D "$DL" >&2
MNT="$(mktemp -d)"; hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$DMG" >/dev/null
trap 'hdiutil detach "$MNT" >/dev/null 2>&1 || true' EXIT
SRC="$(ls -d "$MNT"/*.app)/Contents/MacOS"
cp -f "$SRC"/*.dylib "$KIT/lib/"
cd "$KIT/lib"
ver() { otool -L "$1" | sed -n 2p | sed -E 's/.*current version ([0-9.]+).*/\1/'; }
pc() { # name libfile linkname version
  ln -sf "$2" "lib$3.dylib"
  cat > "$KIT/pkgconfig/$1.pc" <<PC
prefix=$KIT
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: $1
Description: from USDX $TAG release bundle
Version: $4
Libs: -L\${libdir} -l$3
Cflags: -I\${includedir}
PC
}
for f in libavcodec libavformat libavutil libswscale libswresample; do
  file=$(ls $f.[0-9]*.dylib | head -1); pc "$f" "$file" "${f#lib}" "$(ver "$file")"
done
pc sdl2 libSDL2-2.0.0.dylib SDL2 2.32.0  # sdl2-compat (SDL3 underneath)
pc SDL2_image libSDL2_image-2.0.0.dylib SDL2_image 2.8.12
pc freetype2 libfreetype.6.dylib freetype 27.7.0
pc portaudio-2.0 libportaudio.2.dylib portaudio 19.7.0
LUAF=$(ls liblua.5.*.dylib | head -1); LUAV=$(ver "$LUAF"); LUAMM=${LUAV%.*}
pc "lua$LUAMM" "$LUAF" lua "$LUAV"
cat > "$KIT/pkgconfig/sqlite3.pc" <<PC
Name: sqlite3
Description: macOS system sqlite
Version: 3.43.2
Libs: -lsqlite3
Cflags:
PC
for h in lua.h luaconf.h lauxlib.h lualib.h; do
  gh api "repos/lua/lua/contents/$h?ref=v$LUAV" --jq .content | base64 -d > "$KIT/include/$h"
done
touch "$KIT/.done"; echo "$KIT"
