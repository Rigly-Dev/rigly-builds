#!/usr/bin/env bash
# Builds MariaDB from the official source release for the current Mac and packages it for Rigly.
#
#   scripts/build-mariadb.sh 11.8.9
#
# Self-contained: bundled SSL (wolfSSL), zlib and PCRE; Homebrew/local libraries are ignored so the
# binaries only link macOS system libraries. Output: dist/mariadb-<version>-macos-<arch>.tar.gz
# (+ .sha256, .json) containing bin/, lib/, share/, scripts/.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: build-mariadb.sh <version, e.g. 11.8.9>}"
case "$(uname -m)" in arm64) ARCH=aarch64 ;; x86_64) ARCH=x86_64 ;; *) echo "unsupported arch" >&2; exit 1 ;; esac
ROOT="$(pwd)"
WORK="$ROOT/build/mariadb"
NAME="mariadb-$VERSION-macos-$ARCH"
STAGE="$WORK/stage/$NAME"
rm -rf "$WORK" && mkdir -p "$WORK" dist

echo "Downloading MariaDB $VERSION source"
curl -fsSL --retry 3 -o "$WORK/src.tar.gz" "https://archive.mariadb.org/mariadb-$VERSION/source/mariadb-$VERSION.tar.gz"
tar -xzf "$WORK/src.tar.gz" -C "$WORK"

# Keep Homebrew (and anything else in /usr/local) out of the build.
export PKG_CONFIG_PATH="" PKG_CONFIG_LIBDIR=""
cmake -S "$WORK/mariadb-$VERSION" -B "$WORK/obj" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/opt/rigly-mariadb \
    -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
    -DWITH_SSL=bundled -DWITH_ZLIB=bundled -DWITH_PCRE=bundled \
    -DWITH_UNIT_TESTS=OFF -DWITH_WSREP=OFF -DWITH_EMBEDDED_SERVER=OFF -DWITH_MARIABACKUP=OFF \
    -DPLUGIN_ROCKSDB=NO -DPLUGIN_MROONGA=NO -DPLUGIN_SPIDER=NO -DPLUGIN_CONNECT=NO -DPLUGIN_S3=NO \
    -DPLUGIN_OQGRAPH=NO -DPLUGIN_COLUMNSTORE=NO -DPLUGIN_TOKUDB=NO -DPLUGIN_HASHICORP_KEY_MANAGEMENT=NO \
    -DPLUGIN_AUTH_GSSAPI=NO -DPLUGIN_PROVIDER_LZ4=NO -DPLUGIN_PROVIDER_LZO=NO -DPLUGIN_PROVIDER_LZMA=NO \
    -DPLUGIN_PROVIDER_BZIP2=NO -DPLUGIN_PROVIDER_SNAPPY=NO \
    -DINSTALL_MYSQLTESTDIR= -DINSTALL_SQLBENCHDIR= -DINSTALL_DOCDIR=share/doc -DINSTALL_MANDIR=share/man
cmake --build "$WORK/obj" --parallel "$(sysctl -n hw.ncpu)"
DESTDIR="$WORK/destdir" cmake --install "$WORK/obj"

mkdir -p "$STAGE"
INSTALLED="$WORK/destdir/opt/rigly-mariadb"
for dir in bin lib share scripts; do
    [ -d "$INSTALLED/$dir" ] && cp -R "$INSTALLED/$dir" "$STAGE/"
done
rm -rf "$STAGE/share/man" "$STAGE/share/doc" "$STAGE/lib/pkgconfig" "$STAGE/include"
find "$STAGE/lib" -name '*.a' -delete

# Only macOS system libraries (and our own lib/) may be linked.
bad=0
while IFS= read -r f; do
    if file "$f" | grep -q 'Mach-O'; then
        if otool -L "$f" | tail -n +2 | grep -E '/opt/homebrew|/usr/local' ; then echo "  ^ in $f" >&2; bad=1; fi
        codesign --force --sign - "$f" 2>/dev/null || true
    fi
done < <(find "$STAGE/bin" "$STAGE/lib" -type f)
[ $bad = 0 ] || { echo "non-system libraries linked" >&2; exit 1; }

# Smoke test: initialise a data directory, start the server, query it, shut down.
T="$(mktemp -d)"
"$STAGE/scripts/mariadb-install-db" --no-defaults --basedir="$STAGE" --datadir="$T/data" \
    --auth-root-authentication-method=normal --skip-test-db >/dev/null
"$STAGE/bin/mariadbd" --no-defaults --basedir="$STAGE" --datadir="$T/data" --port=33999 \
    --bind-address=127.0.0.1 --socket="$T/s.sock" --pid-file="$T/p.pid" --lc-messages-dir="$STAGE/share" >"$T/log" 2>&1 &
for _ in $(seq 1 30); do [ -S "$T/s.sock" ] && break; sleep 1; done
GOT="$("$STAGE/bin/mariadb" --no-defaults -uroot --socket="$T/s.sock" -N -e 'SELECT VERSION()')" || { cat "$T/log"; exit 1; }
"$STAGE/bin/mariadb-admin" --no-defaults -uroot --socket="$T/s.sock" shutdown
echo "Smoke test: server reports $GOT"
case "$GOT" in "$VERSION"*) ;; *) echo "expected $VERSION" >&2; exit 1 ;; esac
rm -rf "$T"

tar -C "$WORK/stage" -czf "dist/$NAME.tar.gz" "$NAME"
shasum -a 256 "dist/$NAME.tar.gz" | awk '{print $1}' > "dist/$NAME.tar.gz.sha256"
printf '{"product":"mariadb","version":"%s","arch":"%s","built_at":"%s"}\n' "$VERSION" "$ARCH" "$(date -u +%FT%TZ)" > "dist/$NAME.json"
echo "Built dist/$NAME.tar.gz ($(du -h "dist/$NAME.tar.gz" | cut -f1))"
