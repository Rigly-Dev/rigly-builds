#!/usr/bin/env bash
# Builds one PHP version for the current machine (macOS or Linux) and packages it for Rigly.
#
#   scripts/build.sh 8.4.23
#
# macOS: uses the static-php-cli binary (./spc).
# Linux: uses static-php-cli's bin/spc-gnu-docker from a source checkout (spc-src/), which builds
#        inside a CentOS 7 container, so binaries need only glibc 2.17+ (almost every distro except
#        musl ones like Alpine) and can load shared extensions (Xdebug, pcov).
#
# Output: dist/php-<version>-<macos|linux>-<arch>.tar.gz (+ .sha256), containing:
#   php, php-fpm          static binaries (same layout as static-php.dev's bulk builds)
#   ext/xdebug.so, ...    shared extensions Rigly can toggle
#   BUILD.json            version, arch, extension lists, build metadata
#   licenses/             licenses of PHP and every bundled library
set -euo pipefail
cd "$(dirname "$0")/.."

PHP_VERSION="${1:?usage: build.sh <php version, e.g. 8.4.23>}"
MINOR="$(echo "$PHP_VERSION" | cut -d. -f1-2)"
case "$(uname -m)" in
    arm64|aarch64) ARCH=aarch64 ;;
    x86_64) ARCH=x86_64 ;;
    *) echo "unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac
ROOT="$(pwd)"
SPC_VERSION="${SPC_VERSION:-2.8.5}"
case "$(uname -s)" in
    Darwin) PLATFORM=macos; WORK="$ROOT"; SPC_BIN="${SPC:-./spc}"; ARCH_KEY="$ARCH" ;;
    Linux)
        PLATFORM=linux; WORK="$ROOT/spc-src"; SPC_BIN="bin/spc-gnu-docker"; ARCH_KEY="linux-$ARCH"
        [ -d "$WORK" ] || git clone --depth 1 --branch "$SPC_VERSION" https://github.com/crazywhalecc/static-php-cli "$WORK"
        ;;
    *) echo "unsupported OS $(uname -s)" >&2; exit 1 ;;
esac
# Runs static-php-cli from its working directory (paths below are relative to it).
spc() { (cd "$WORK" && "$SPC_BIN" "$@"); }

# Reads an extension list, dropping comments and entries excluded for this minor ("name !8.5").
read_list() {
    sed -e 's/#.*//' "$1" | while read -r name flags; do
        [ -z "$name" ] && continue
        case " $flags " in *" !$MINOR "*) echo "skipping $name for PHP $MINOR" >&2; continue ;; esac
        echo "$name"
    done | paste -sd, -
}
STATIC_EXTS="$(read_list extensions.txt)"
SHARED_EXTS="$(read_list shared-extensions.txt)"
echo "PHP $PHP_VERSION ($ARCH)"
echo "static: $STATIC_EXTS"
echo "shared: $SHARED_EXTS"

# On Linux the Docker image runs doctor while it is built.
[ "$PLATFORM" = macos ] && spc doctor --auto-fix
spc download --with-php="$PHP_VERSION" --for-extensions="$STATIC_EXTS,$SHARED_EXTS" --prefer-pre-built --retry=3
spc build "$STATIC_EXTS" --build-cli --build-fpm --build-shared="$SHARED_EXTS" --debug

BUILDROOT="$WORK/buildroot"
BUILT="$("$BUILDROOT/bin/php" -r 'echo PHP_VERSION;')"
if [ "$BUILT" != "$PHP_VERSION" ]; then
    echo "built PHP $BUILT but asked for $PHP_VERSION" >&2
    exit 1
fi

NAME="php-$PHP_VERSION-$PLATFORM-$ARCH"
OUT="dist/$NAME"
rm -rf "$OUT" && mkdir -p "$OUT/ext" "$OUT/licenses"
cp "$BUILDROOT/bin/php" "$OUT/php"
cp "$BUILDROOT/bin/php-fpm" "$OUT/php-fpm"
for ext in ${SHARED_EXTS//,/ }; do
    cp "$BUILDROOT/modules/$ext.so" "$OUT/ext/$ext.so"
done
# dist/ is mounted into the Linux build container, so dump licenses there and move them.
if spc dump-license --for-extensions="$STATIC_EXTS,$SHARED_EXTS" --dump-dir="dist/licenses-tmp"; then
    cp -R "$WORK/dist/licenses-tmp/." "$OUT/licenses/" && rm -rf "$WORK/dist/licenses-tmp" 2>/dev/null || true
else
    echo "warning: license dump failed" >&2
fi

if [ "$PLATFORM" = macos ]; then
    # Ad-hoc sign so the binaries run on Apple Silicon after being moved around.
    codesign --force --sign - "$OUT/php" "$OUT/php-fpm" "$OUT"/ext/*.so
fi

SPC_REPORTED="$(spc --version 2>/dev/null | tail -1 || true)"
python3 - "$OUT" "$PHP_VERSION" "$ARCH_KEY" "$STATIC_EXTS" "$SHARED_EXTS" "$SPC_REPORTED" <<'PY'
import json, subprocess, sys, datetime, os
out, version, arch, static, shared, spc = sys.argv[1:]
modules = subprocess.run([os.path.join(out, "php"), "-n", "-m"], capture_output=True, text=True, check=True).stdout
loaded = sorted({m.strip() for m in modules.splitlines() if m.strip() and not m.startswith("[")}, key=str.lower)
json.dump({
    "php": version,
    "arch": arch,
    "extensions": loaded,
    "requested": static.split(","),
    "shared": shared.split(",") if shared else [],
    "built_at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
    "spc": spc.strip(),
}, open(os.path.join(out, "BUILD.json"), "w"), indent=2)
PY

scripts/smoke-test.sh "$OUT"

tar -czf "dist/$NAME.tar.gz" -C "$OUT" .
shasum -a 256 "dist/$NAME.tar.gz" | cut -d' ' -f1 > "dist/$NAME.tar.gz.sha256"
cp "$OUT/BUILD.json" "dist/$NAME.json"
echo "✓ dist/$NAME.tar.gz"
