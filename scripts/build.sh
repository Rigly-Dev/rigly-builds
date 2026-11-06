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
# Newer autoconf switches clang to C23 (-std=gnu23), which removed the K&R-style function
# definitions PHP 8.1/8.2 still use (e.g. ext/bcmath). Tell configure C23 isn't available.
case "$MINOR" in 7.4|8.0|8.1|8.2) export ac_cv_prog_cc_c23=no ;; esac

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
# static-php-cli rejects OPcache below 8.0 even when it's built shared (as we do for 7.4); its
# guard is meant for the static case. Set via config/env.custom.ini, which spc reads on macOS and
# inside the Linux container (where shell environment variables aren't passed through).
# The value is quoted: unquoted, PHP's INI parser turns "yes" into "1" and spc compares against "yes".
mkdir -p "$WORK/config"
if [ "$MINOR" = 7.4 ]; then
    # 7.4's ext/libxml passes a non-const error handler where libxml2 2.12+ expects a const one;
    # current Apple clang makes that an error, so keep it a warning (spc's macOS default plus one flag).
    cat > "$WORK/config/env.custom.ini" <<'INI'
[global]
SPC_SKIP_PHP_VERSION_CHECK="yes"
[macos]
SPC_CMD_VAR_PHP_MAKE_EXTRA_CFLAGS="-g -fstack-protector-strong -fpic -fpie -Werror=unknown-warning-option -Wno-error=incompatible-function-pointer-types ${SPC_DEFAULT_C_FLAGS}"
INI
else
    rm -f "$WORK/config/env.custom.ini"
fi

# Runs static-php-cli from its working directory (paths below are relative to it).
spc() { (cd "$WORK" && "$SPC_BIN" "$@"); }

# True if version $1 >= version $2.
version_ge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$2" ]; }
# True if every version rule ("!8.5", ">=8.2", "<8.4") matches this PHP minor version.
rules_match() {
    local rule
    for rule in "$@"; do
        case "$rule" in
            !*) [ "$MINOR" != "${rule#!}" ] || return 1 ;;
            ">="*) version_ge "$MINOR" "${rule#>=}" || return 1 ;;
            "<"*) ! version_ge "$MINOR" "${rule#<}" || return 1 ;;
            *) echo "unknown version rule '$rule'" >&2; exit 1 ;;
        esac
    done
}
# Reads an extension list, dropping comments and entries whose version rules don't match.
read_list() {
    sed -e 's/#.*//' "$1" | while read -r name rules; do
        [ -z "$name" ] && continue
        # shellcheck disable=SC2086
        rules_match $rules || { echo "skipping $name for PHP $MINOR" >&2; continue; }
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
# Pinned sources (pinned-sources.txt) override static-php-cli's default download URLs.
PIN_ARGS=()
PINNED=php-src
while read -r src url rules; do
    [ -z "$src" ] && continue
    # shellcheck disable=SC2086
    rules_match $rules || continue
    echo "pinned: $src $url"
    PIN_ARGS+=(-U "$src:$url")
    PINNED="$PINNED,$src"
done < <(sed -e 's/#.*//' pinned-sources.txt)

# The downloads cache may come from another PHP version's job; always fetch php-src (and pinned
# sources) fresh, or static-php-cli reuses the cached copies and builds the wrong version.
spc download --with-php="$PHP_VERSION" --for-extensions="$STATIC_EXTS,$SHARED_EXTS" --prefer-pre-built --retry=3 \
    --ignore-cache-sources="$PINNED" "${PIN_ARGS[@]}"
# macOS: build curl without c-ares. gRPC/Swoole pull c-ares in and curl then uses it, but c-ares
# ignores /etc/resolver/<tld>, so PHP couldn't reach other local sites (e.g. https://api.test).
# Without it curl uses the system resolver (threaded), which honours per-domain resolvers.
if [ "$PLATFORM" = macos ]; then
    spc extract curl --source-only
    perl -0pi -e 's/^(option\(ENABLE_ARES [^\n]*\))$/$1\nset(ENABLE_ARES OFF CACHE BOOL "Rigly: use the macOS resolver" FORCE)/m' "$WORK/source/curl/CMakeLists.txt"
    grep -q 'Rigly: use the macOS resolver' "$WORK/source/curl/CMakeLists.txt" || { echo "curl c-ares patch failed" >&2; exit 1; }
fi
# PHP 7.4/8.0 source fixes for current toolchains:
#  - GD's configure test defines `char foobar () {}` (no return value); current Apple clang traps on
#    it, so the test program crashes and configure reports "GD build test failed".
#  - ICU 75+ headers need C++17, but 7.4/8.0's ext/intl asks for C++11.
case "$MINOR" in 7.4|8.0)
    spc extract php-src --source-only
    # On Linux the sources were unpacked inside the build container, so they are owned by root.
    if [ ! -w "$WORK/source/php-src/ext/gd/config.m4" ]; then sudo chown -R "$(id -u):$(id -g)" "$WORK/source"; fi
    # The test program links every static library configured so far and crashes at start-up on
    # 7.4 (SIGILL) even with a valid test body; drop the test. Our smoke test still runs the
    # finished binary, so a real crash would fail the build there.
    perl -0pi -e 's/PHP_TEST_BUILD\(foobar,.*?\[char foobar[^\]]*\]\)/dnl Rigly: GD build test removed/s' "$WORK/source/php-src/ext/gd/config.m4"
    perl -pi -e 's/PHP_CXX_COMPILE_STDCXX\(11,/PHP_CXX_COMPILE_STDCXX(17,/' "$WORK/source/php-src/ext/intl/config.m4"
    # ICU's own flags (added after PHP's) carry -std=c++11, and the last -std wins: force 17 at the end.
    perl -pi -e 's/^(\s*PHP_INTL_CXX_FLAGS="\$INTL_COMMON_FLAGS \$PHP_INTL_STDCXX \$ICU_CXXFLAGS)"/$1 -std=c++17"/' "$WORK/source/php-src/ext/intl/config.m4"
    grep -q 'ICU_CXXFLAGS -std=c++17"' "$WORK/source/php-src/ext/intl/config.m4" || { echo "intl -std patch failed" >&2; exit 1; }
    grep -q 'Rigly: GD build test removed' "$WORK/source/php-src/ext/gd/config.m4" || { echo "GD patch failed" >&2; exit 1; }
    grep -q 'PHP_CXX_COMPILE_STDCXX(17,' "$WORK/source/php-src/ext/intl/config.m4" || { echo "intl patch failed" >&2; exit 1; }
    # 7.4 names its embed library libphp7.a; static-php-cli expects PHP 8's libphp.a.
    if [ "$MINOR" = 7.4 ]; then
        perl -pi -e 's/libphp\[\]\$PHP_MAJOR_VERSION/libphp/g' "$WORK/source/php-src/configure.ac" "$WORK/source/php-src/build/php.m4"
        perl -pi -e 's/libphp\$\(PHP_MAJOR_VERSION\)/libphp/g' "$WORK/source/php-src/build/Makefile.global"
        ! grep -qE 'libphp(\[\]\$PHP_MAJOR_VERSION|\$\(PHP_MAJOR_VERSION\))' "$WORK/source/php-src/configure.ac" \
            "$WORK/source/php-src/build/php.m4" "$WORK/source/php-src/build/Makefile.global" \
            || { echo "libphp name patch failed" >&2; exit 1; }
    fi
    # zend_string_equal_val's x86_64 inline asm uses labels like ".LL0"; in Mach-O only "L…" labels are local,
    # so ".LL…" become symbols, the linker treats them as separate atoms, and the function gets split apart:
    # the Intel macOS CLI aborts at startup (stack-protector failure in module startup). Make them local.
    if [ "$(uname -s)" = Darwin ]; then
        perl -pi -e 's/\.LL(\d)/LL$1/g' "$WORK/source/php-src/Zend/zend_string.c"
        ! grep -q '\.LL[0-9]' "$WORK/source/php-src/Zend/zend_string.c" || { echo "asm label patch failed" >&2; exit 1; }
    fi
    # sqlsrv/pdo_sqlsrv 5.10 (pinned below 8.1) append -std=c++11 to the global CXXFLAGS, which come
    # after intl's -std=c++17 and win; ICU 75+ headers need C++17.
    spc extract sqlsrv,pdo_sqlsrv --source-only
    for ext in sqlsrv pdo_sqlsrv; do
        perl -pi -e 's/-std=c\+\+11/-std=c++17/g' "$WORK/source/php-src/ext/$ext/config.m4"
        ! grep -q 'std=c++11' "$WORK/source/php-src/ext/$ext/config.m4" || { echo "$ext -std patch failed" >&2; exit 1; }
    done
    # Where a PHP is on PATH (the Linux build container), make regenerates extensions' *_arginfo.h
    # from their stubs with 8.0's gen_stub.php, which can't parse newer stubs (ext-zstd's `const`:
    # "Unexpected node Stmt_Const"). Extensions ship their arginfo headers, so keep those: make the
    # generator a no-op (the file must stay, `make install-build` copies it).
    printf '<?php\n// Rigly: arginfo regeneration disabled for PHP %s builds.\n' "$MINOR" > "$WORK/source/php-src/build/gen_stub.php"
    ;;
esac
BUILD_FLAGS=()
# PHP 8.0's OPcache JIT (x86_64 only; arm64 has no JIT before 8.1) makes the Intel macOS binary abort at
# startup with a stack-protector failure during module startup. 7.4 has no JIT.
if [ "$MINOR" = 8.0 ] && [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = x86_64 ]; then
    # Kept off while the startup abort was diagnosed (the cause was zend_string.c's asm labels, patched
    # above); the JIT matters little for local development.
    BUILD_FLAGS+=(--disable-opcache-jit)
fi
spc build "$STATIC_EXTS" --build-cli --build-fpm --build-shared="$SHARED_EXTS" --debug ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"}

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
import json, re, subprocess, sys, datetime, os
out, version, arch, static, shared, spc = sys.argv[1:]
modules = subprocess.run([os.path.join(out, "php"), "-n", "-m"], capture_output=True, text=True, check=True).stdout
loaded = sorted({m.strip() for m in modules.splitlines() if m.strip() and not m.startswith("[")}, key=str.lower)
# Version of each loadable extension, so pre-releases can't slip in unnoticed.
shared_versions = {}
for name in (shared.split(",") if shared else []):
    directive = "zend_extension" if name in ("xdebug", "opcache") else "extension"
    module = "Zend OPcache" if name == "opcache" else name
    so = os.path.abspath(os.path.join(out, "ext", f"{name}.so"))
    v = subprocess.run([os.path.join(out, "php"), "-n", "-d", f"{directive}={so}", "-r", f"echo phpversion('{module}');"],
                       capture_output=True, text=True).stdout.strip()
    shared_versions[name] = v if re.fullmatch(r"[0-9][0-9A-Za-z.\-]*", v) else ""
json.dump({
    "php": version,
    "arch": arch,
    "extensions": loaded,
    "requested": static.split(","),
    "shared": shared.split(",") if shared else [],
    "shared_versions": shared_versions,
    "built_at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
    "spc": spc.strip(),
}, open(os.path.join(out, "BUILD.json"), "w"), indent=2)
PY

scripts/smoke-test.sh "$OUT"

tar -czf "dist/$NAME.tar.gz" -C "$OUT" .
shasum -a 256 "dist/$NAME.tar.gz" | cut -d' ' -f1 > "dist/$NAME.tar.gz.sha256"
cp "$OUT/BUILD.json" "dist/$NAME.json"
echo "✓ dist/$NAME.tar.gz"
