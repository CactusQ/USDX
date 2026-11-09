#!/bin/bash
set -e
cd "$HOME/src/usdx-toolchain/src/projectm"
P="$HOME/src/usdx-toolchain/projectm-arm64"
export MACOSX_DEPLOYMENT_TARGET=11.0
nice -n 15 cmake -S . -B build-arm64 -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$P" -DBUILD_SHARED_LIBS=ON -DENABLE_PLAYLIST=OFF -DBUILD_TESTING=OFF \
  -DENABLE_SDL_UI=OFF -DCMAKE_C_COMPILER=/usr/bin/clang -DCMAKE_CXX_COMPILER=/usr/bin/clang++
nice -n 15 cmake --build build-arm64 -j2
cmake --install build-arm64
file "$P"/lib/libprojectM-4*.dylib
