# source me inside an arm64 shell: sets FPC + kit env for building USDX arm64
TC="${USDX_TOOLCHAIN:-$HOME/src/usdx-toolchain}"
KIT_TAG="${KIT_TAG:-$(ls -1 "$TC/kit" | sort -V | tail -1)}"
export KIT="$TC/kit/$KIT_TAG"
export PATH="$TC/fpc/bin:$PATH"
export PPC_CONFIG_PATH="$TC/fpc/etc"
export PKG_CONFIG_LIBDIR="$KIT/pkgconfig"
export PKG_CONFIG_PATH=""
export CC="clang -arch arm64" CXX="clang++ -arch arm64"
export CFLAGS="-I$KIT/include" LDFLAGS="-L$KIT/lib"
export MACOSX_DEPLOYMENT_TARGET=11.0
export MAKE_ARCH_ARGS="PPC=fpc -Paarch64"
