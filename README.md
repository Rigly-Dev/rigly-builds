# Rigly PHP builds

PHP builds for macOS (Apple Silicon and Intel), Linux (x86_64 and arm64) and Windows (x64), made with
[static-php-cli](https://github.com/crazywhalecc/static-php-cli) for Rigly, a local PHP development environment for macOS.

Each PHP minor version (8.1–8.5) is built with the extensions in `extensions.txt` compiled in,
plus `shared-extensions.txt` (Xdebug, pcov) as loadable `.so` files that Rigly toggles per version.
Compared with static-php.dev's bulk builds this adds a complete `pdo_sqlite`/`pdo_pgsql`, Xdebug,
pcov, igbinary, msgpack, memcached, mongodb, sqlsrv, grpc, gettext, ldap, tidy, excimer, uuid and zstd.

## How it works

`.github/workflows/build-php.yml` runs weekly (and on demand):

1. **plan**: asks php.net for each minor's latest patch and skips versions already released.
2. **build**: one job per version × architecture (`macos-15`, `macos-15-intel`) runs
   `scripts/build.sh <version>`, which builds with static-php-cli, packages
   `php`, `php-fpm`, `ext/*.so`, `BUILD.json` and licenses, and runs `scripts/smoke-test.sh`
   (every extension loads, full PDO SQLite incl. `Pdo\Sqlite`/UDFs, Imagick renders, shared
   extensions load, php-fpm config test).
3. **release**: uploads each build to a `php-<version>` release and merges it into
   `manifest.json` on the fixed `manifest` release, which Rigly reads:
   `https://github.com/<owner>/<repo>/releases/download/manifest/manifest.json`

## Changing extensions

Edit `extensions.txt`. To skip an extension for one PHP version (e.g. it doesn't support it yet),
append `!<minor>`: `swoole !8.5`. Then run the workflow with **force** to rebuild.

## Building locally

```
curl -fsSL -o spc.tgz https://github.com/crazywhalecc/static-php-cli/releases/download/2.8.5/spc-macos-aarch64.tar.gz
tar -xzf spc.tgz && scripts/build.sh 8.4.23
```

Note: `sqlsrv`/`pdo_sqlsrv` also need Microsoft's ODBC driver (msodbcsql18) installed to connect.

## Windows

`.github/workflows/build-php-windows.yml` packages the official windows.php.net NTS x64 build
(which already includes intl, gd, gmp, xsl, ldap, tidy, gettext, sodium, curl, pdo_sqlite,
pdo_pgsql, ...) with PECL extensions compiled by
[php/php-windows-builder](https://github.com/php/php-windows-builder): Imagick (with ImageMagick's
DLLs), Redis, igbinary, msgpack, APCu, MongoDB, zstd, sqlsrv/pdo_sqlsrv, Xdebug and pcov — see
`windows-extensions.json`. Each package has a `php.ini-rigly` with everything enabled except
Xdebug, pcov and sqlsrv, and is smoke-tested before release. Index: `manifest-windows.json` on
the `manifest` release.

Not available on Windows: pcntl, posix, sysv*, swoole (Unix-only), and memcached/event (no
Windows builds of their libraries).

## Linux

`.github/workflows/build-php-linux.yml` runs the same `scripts/build.sh` on `ubuntu-24.04` and
`ubuntu-24.04-arm`. On Linux it uses static-php-cli's `bin/spc-gnu-docker`, which builds inside a
CentOS 7 container: everything is statically linked except glibc, so the binaries run on any
distro with glibc 2.17+ (not musl distros like Alpine) and can load the shared Xdebug/pcov
extensions. Same extension set as macOS. Index: `manifest-linux.json` on the `manifest` release.
