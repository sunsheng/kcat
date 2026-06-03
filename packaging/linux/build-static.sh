#!/usr/bin/env bash
#
# Build a fully self-contained, statically-linked Linux kcat binary.
#
# The only runtime dependency of the produced ./kcat is glibc: librdkafka and
# all of its compression/TLS dependencies (OpenSSL, zlib, zstd, lz4, snappy)
# are linked in statically. Snappy is bundled in librdkafka's sources and is
# enabled by default in the mklove/autoconf build, so no extra flag is needed.
#
# To run on CentOS 7 (kernel 3.10, glibc 2.17) this script must be executed in
# a matching-or-older glibc userland; CI runs it inside the manylinux2014
# (CentOS 7 / glibc 2.17) container. Building there means the binary references
# no glibc symbol newer than 2.17, so it loads on CentOS 7 and anything newer.
#
set -o errexit -o nounset -o pipefail

: "${LIBRDKAFKA_VERSION:=v2.6.1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORK="$SRC/tmp-linux-build"
DEST="$WORK/dest"
JOBS="$(nproc 2>/dev/null || echo 2)"

mkdir -p "$WORK" "$DEST"

echo "== Building self-contained librdkafka $LIBRDKAFKA_VERSION =="

# 1. librdkafka, statically linked with its dependencies built from source.
#    --source-deps-only forces OpenSSL/zlib/zstd to be downloaded and compiled
#    as static archives instead of pulling the host's (dynamic) system copies,
#    which is what makes the final kcat a single self-contained file.
if [[ ! -d "$WORK/librdkafka" ]]; then
    url="https://github.com/confluentinc/librdkafka/archive/refs/tags/${LIBRDKAFKA_VERSION}.tar.gz"
    echo "Downloading $url"
    mkdir -p "$WORK/librdkafka"
    curl -sSL "$url" | tar -xz -C "$WORK/librdkafka" --strip-components 1
fi

pushd "$WORK/librdkafka" >/dev/null
if [[ ! -f config.h ]]; then
    ./configure --prefix="$DEST" \
        --install-deps --source-deps-only \
        --enable-static --disable-lz4-ext
fi
make -j"$JOBS"
make install
popd >/dev/null

echo "== Building static kcat =="

# 2. kcat, linked against the self-contained static librdkafka.
#    mklove links $STATIC_LIB_rdkafka (the .a) directly and appends $LIBS for
#    librdkafka's transitive static dependencies (OpenSSL/zlib/zstd/... and the
#    handful of system libs they pull in: -ldl -lpthread -lm -lrt -lcrypt ...).
export PKG_CONFIG_PATH="$DEST/lib/pkgconfig"
export CPPFLAGS="${CPPFLAGS:-} -I$DEST/include"
export LDFLAGS="${LDFLAGS:-} -L$DEST/lib -Wl,-rpath-link=$DEST/lib"
export STATIC_LIB_rdkafka="$DEST/lib/librdkafka.a"

# Pull the transitive dependency list out of librdkafka's static pkg-config
# file, dropping the -lrdkafka* entries (we link the .a explicitly above).
pc_name="rdkafka-static"
pkg-config --exists "$pc_name" 2>/dev/null || pc_name="rdkafka"
extra_libs="$(pkg-config --libs --static "$pc_name" | \
    sed -e 's/-lrdkafka-static//g' -e 's/-lrdkafka//g')"
export LIBS="$extra_libs"
echo "Transitive static libs: $LIBS"

cd "$SRC"
./configure --clean >/dev/null 2>&1 || true
# JSON/Avro are intentionally left off to keep the binary a single self-contained
# file (matches the Windows build's feature set: gzip,snappy,ssl,sasl,lz4,zstd).
./configure --enable-static --disable-json --disable-avro
make -j"$JOBS"

echo "== Verifying the binary =="
./kcat -V

# 3a. No third-party shared objects may remain -- only glibc is allowed.
echo "-- ldd ./kcat --"
ldd ./kcat || true
if ldd ./kcat | grep -Eiq 'librdkafka|libssl|libcrypto|libz\.so|libzstd|liblz4|libsasl|libsnappy'; then
    echo "ERROR: kcat still links a third-party shared library; build is not self-contained." >&2
    exit 1
fi

# 3b. The binary must not require a glibc newer than CentOS 7's 2.17.
maxglibc="$(objdump -T ./kcat 2>/dev/null \
    | grep -oE 'GLIBC_[0-9]+\.[0-9]+(\.[0-9]+)?' \
    | sed 's/GLIBC_//' | sort -V | tail -1)"
echo "Highest required GLIBC symbol: ${maxglibc:-none}"
if [[ -n "$maxglibc" ]]; then
    highest="$(printf '%s\n2.17\n' "$maxglibc" | sort -V | tail -1)"
    if [[ "$highest" != "2.17" ]]; then
        echo "ERROR: kcat requires GLIBC $maxglibc (> 2.17); it will not run on CentOS 7." >&2
        exit 1
    fi
fi

# 3c. Snappy must actually be compiled in (parity with the Windows build).
if ! ./kcat -V | grep -q 'snappy'; then
    echo "ERROR: kcat -V does not report snappy support." >&2
    exit 1
fi

echo "== Self-contained kcat built successfully: $SRC/kcat =="
