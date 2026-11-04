#!/usr/bin/env bash
# Builds one PHP version for the current Mac architecture and packages it for Rigly.
#
#   scripts/build.sh 8.4.23
#
# Output: dist/php-<version>-macos-<arch>.tar.gz (+ .sha256), containing:
#   php, php-fpm          static binaries (same layout as static-php.dev's bulk builds)
#   ext/xdebug.so, ...    shared extensions Rigly can toggle
#   BUILD.json            version, arch, extension lists, build metadata
#   licenses/             licenses of PHP and every bundled library
set -euo pipefail
cd "$(dirname "$0")/.."

PHP_VERSION="${1:?usage: build.sh <php version, e.g. 8.4.23>}"
MINOR="$(echo "$PHP_VERSION" | cut -d. -f1-2)"
case "$(uname -m)" in
    arm64) ARCH=aarch64 ;;
    x86_64) ARCH=x86_64 ;;
    *) echo "unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac
SPC="${SPC:-./spc}"

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

"$SPC" doctor --auto-fix
"$SPC" download --with-php="$PHP_VERSION" --for-extensions="$STATIC_EXTS,$SHARED_EXTS" --prefer-pre-built --retry=3
"$SPC" build "$STATIC_EXTS" --build-cli --build-fpm --build-shared="$SHARED_EXTS" --debug

BUILT="$(./buildroot/bin/php -r 'echo PHP_VERSION;')"
if [ "$BUILT" != "$PHP_VERSION" ]; then
    echo "built PHP $BUILT but asked for $PHP_VERSION" >&2
    exit 1
fi

NAME="php-$PHP_VERSION-macos-$ARCH"
OUT="dist/$NAME"
rm -rf "$OUT" && mkdir -p "$OUT/ext" "$OUT/licenses"
cp buildroot/bin/php "$OUT/php"
cp buildroot/bin/php-fpm "$OUT/php-fpm"
for ext in ${SHARED_EXTS//,/ }; do
    cp "buildroot/modules/$ext.so" "$OUT/ext/$ext.so"
done
"$SPC" dump-license --for-extensions="$STATIC_EXTS,$SHARED_EXTS" --dump-dir="$OUT/licenses" || echo "warning: license dump failed" >&2

# Ad-hoc sign so the binaries run on Apple Silicon after being moved around.
codesign --force --sign - "$OUT/php" "$OUT/php-fpm" "$OUT"/ext/*.so

python3 - "$OUT" "$PHP_VERSION" "$ARCH" "$STATIC_EXTS" "$SHARED_EXTS" <<'PY'
import json, subprocess, sys, datetime, os
out, version, arch, static, shared = sys.argv[1:]
modules = subprocess.run([os.path.join(out, "php"), "-n", "-m"], capture_output=True, text=True, check=True).stdout
loaded = sorted({m.strip() for m in modules.splitlines() if m.strip() and not m.startswith("[")}, key=str.lower)
json.dump({
    "php": version,
    "arch": arch,
    "extensions": loaded,
    "requested": static.split(","),
    "shared": shared.split(",") if shared else [],
    "built_at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
    "spc": subprocess.run(["./spc", "--version"], capture_output=True, text=True).stdout.strip(),
}, open(os.path.join(out, "BUILD.json"), "w"), indent=2)
PY

scripts/smoke-test.sh "$OUT"

tar -czf "dist/$NAME.tar.gz" -C "$OUT" .
shasum -a 256 "dist/$NAME.tar.gz" | cut -d' ' -f1 > "dist/$NAME.tar.gz.sha256"
cp "$OUT/BUILD.json" "dist/$NAME.json"
echo "✓ dist/$NAME.tar.gz"
