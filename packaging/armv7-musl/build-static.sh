#!/usr/bin/env bash
#
# Cross-compile a fully static linux-armv7 (musl, hard-float) kcat binary.
#
# The produced ./kcat is statically linked against musl libc, librdkafka and
# yajl (JSON), so it has no runtime dependencies and runs on any ARMv7 (armhf)
# Linux system. It is meant to be executed inside the dockcross/linux-armv7l-musl
# cross-compiler image, which exports the cross toolchain via $CC/$CROSS_TRIPLE
# and the cmake toolchain via $CMAKE_TOOLCHAIN_FILE.
#
# TLS (OpenSSL) and SASL/GSSAPI are intentionally disabled to keep the build
# self-contained and avoid cross-compiling OpenSSL/cyrus-sasl; this binary can
# only talk to PLAINTEXT brokers.
#
# Local use:
#   docker run --rm -v "$PWD":/work -w /work \
#       dockcross/linux-armv7l-musl bash packaging/armv7-musl/build-static.sh
#
set -o errexit -o nounset -o pipefail

: "${LIBRDKAFKA_VERSION:=v1.8.2}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORK="$SRC/tmp-armv7-build"
DEST="$WORK/dest"
JOBS="$(nproc 2>/dev/null || echo 2)"

mkdir -p "$WORK" "$DEST"

echo "== Cross toolchain: ${CC:-?} (${CROSS_TRIPLE:-?}) =="

export CFLAGS="-I$DEST/include"
# Dependency builds use a normal link: a global -static here would break yajl's
# cmake build (it links its own test exes against the shared libyajl). -static
# is applied only to kcat's final link further down.
export LDFLAGS="-L$DEST/lib -Wl,-rpath-link=$DEST/lib"
export CPPFLAGS="-I$DEST/include"
export PKG_CONFIG_PATH="$DEST/lib/pkgconfig"

# --- librdkafka (static) ---------------------------------------------------
if [[ ! -d "$WORK/librdkafka" ]]; then
    echo "== Downloading librdkafka $LIBRDKAFKA_VERSION =="
    mkdir -p "$WORK/librdkafka"
    wget -q -O- "https://github.com/edenhill/librdkafka/archive/${LIBRDKAFKA_VERSION}.tar.gz" \
        | tar -xz --strip-components 1 -C "$WORK/librdkafka" -f -
fi
(
    cd "$WORK/librdkafka"
    # mklove auto-detects the cross $CC. Disable features needing extra
    # cross-compiled libraries; bundled zstd/lz4 still build via $CC.
    [[ -f config.h ]] || ./configure --prefix="$DEST" --enable-static \
        --disable-lz4-ext --disable-ssl --disable-gssapi
    make -j"$JOBS"
    make install
)

# --- yajl (JSON support for kcat -J) ---------------------------------------
if [[ ! -d "$WORK/libyajl" ]]; then
    echo "== Downloading yajl =="
    mkdir -p "$WORK/libyajl"
    wget -q -O- "https://github.com/edenhill/yajl/archive/edenhill.tar.gz" \
        | tar -xz --strip-components 1 -C "$WORK/libyajl" -f -
fi
(
    cd "$WORK/libyajl"
    # dockcross exports CMAKE_TOOLCHAIN_FILE so cmake cross-compiles.
    [[ -d build ]] || cmake -H. -Bbuild \
        -DCMAKE_INSTALL_PREFIX="$DEST" -DCMAKE_BUILD_TYPE=Release
    cmake --build build --target install
    # yajl installs its .pc under share/; move it where pkg-config looks.
    cp -v "$DEST"/share/pkgconfig/*.pc "$DEST/lib/pkgconfig/" 2>/dev/null || true
)

# --- kcat ------------------------------------------------------------------
echo "== Building kcat =="
cd "$SRC"
./configure --clean || true
# Now force a fully static link (musl libc included) for the kcat binary.
export LDFLAGS="-static -L$DEST/lib -Wl,-rpath-link=$DEST/lib"
export STATIC_LIB_rdkafka="$DEST/lib/librdkafka.a"
export STATIC_LIB_yajl="$DEST/lib/libyajl_s.a"
# Pull librdkafka's static secondary deps, minus -lrdkafka (given as a .a above).
export LIBS="$(pkg-config --libs --static rdkafka 2>/dev/null | sed -e 's/-lrdkafka//g')"

./configure --enable-static --enable-json
make -j"$JOBS"

"${CROSS_TRIPLE}-strip" ./kcat

echo ""
echo "== Build complete =="
file ./kcat
"${CROSS_TRIPLE}-readelf" -d ./kcat 2>/dev/null | grep NEEDED \
    || echo "(no dynamic dependencies — fully static)"
