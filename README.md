# Rigly PHP builds

Static PHP builds for macOS (Apple Silicon and Intel), made with
[static-php-cli](https://github.com/crazywhalecc/static-php-cli) for [Rigly](https://github.com/).

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
