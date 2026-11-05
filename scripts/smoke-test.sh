#!/usr/bin/env bash
# Checks a packaged build actually works before it's published.
#   scripts/smoke-test.sh dist/php-8.4.23-macos-aarch64
set -euo pipefail
DIR="$(cd "${1:?usage: smoke-test.sh <package dir>}" && pwd)"
PHP="$DIR/php"
fail=0
check() { # name, command...
    local name="$1"; shift
    if "$@" >/tmp/rigly-smoke.out 2>&1; then echo "  ✓ $name"; else echo "  ✗ $name"; sed 's/^/      /' /tmp/rigly-smoke.out; fail=1; fi
}

echo "Smoke testing $(basename "$DIR")"
check "php runs" "$PHP" -n -v
FPM_CONF="$(mktemp)"
printf '[global]\nerror_log=/dev/null\n[www]\nlisten=/tmp/rigly-smoke-fpm.sock\npm=static\npm.max_children=1\n' > "$FPM_CONF"
check "php-fpm config test" "$DIR/php-fpm" -n -t -y "$FPM_CONF"

# Every requested extension is loaded (pseudo-extensions that aren't modules are skipped).
check "requested extensions loaded" "$PHP" -n -r '
    $build = json_decode(file_get_contents($argv[1]), true);
    $skip = ["mbregex", "mysqlnd"];
    $alias = ["opcache" => "Zend OPcache"];
    $missing = [];
    foreach ($build["requested"] as $ext) {
        if (in_array($ext, $skip, true)) continue;
        if (!extension_loaded($alias[$ext] ?? $ext)) $missing[] = $ext;
    }
    if ($missing) { fwrite(STDERR, "missing: " . implode(", ", $missing) . "\n"); exit(1); }
' "$DIR/BUILD.json"

# The reason these builds exist: a complete PDO SQLite driver.
check "pdo_sqlite is complete" "$PHP" -n -r '
    if (!extension_loaded("pdo_sqlite")) exit(1);
    $pdo = new PDO("sqlite::memory:");
    if (PHP_VERSION_ID >= 80400 && !class_exists("Pdo\\Sqlite")) { fwrite(STDERR, "no Pdo\\Sqlite\n"); exit(1); }
    $pdo->sqliteCreateFunction("twice", fn ($x) => $x * 2, 1);
    exit($pdo->query("SELECT twice(21)")->fetchColumn() == 42 ? 0 : 1);
'
check "pdo_pgsql registered" "$PHP" -n -r 'exit(extension_loaded("pdo_pgsql") && in_array("pgsql", PDO::getAvailableDrivers()) ? 0 : 1);'
check "imagick renders" "$PHP" -n -r '$i = new Imagick("logo:"); $i->setImageFormat("png"); exit(strlen($i->getImageBlob()) > 1000 ? 0 : 1);'
check "intl works (with ICU data)" "$PHP" -n -r 'exit(strpos((new NumberFormatter("de_DE", NumberFormatter::DECIMAL))->format(1234.5), "1.234,5") !== false ? 0 : 1);'
check "openssl + curl https" "$PHP" -n -r 'exit(in_array("https", curl_version()["protocols"]) && openssl_random_pseudo_bytes(8) ? 0 : 1);'

check "no pre-release shared extensions" "$PHP" -n -r '
    $v = json_decode(file_get_contents($argv[1]), true)["shared_versions"] ?? [];
    foreach ($v as $name => $version) {
        // Stable releases only: a plain x.y.z (anything else is a pre-release or a failed load).
        if (!preg_match("/^\\d+\\.\\d+\\.\\d+$/", $version)) { fwrite(STDERR, "$name $version\n"); exit(1); }
        echo "$name $version\n";
    }
' "$DIR/BUILD.json"

for so in "$DIR"/ext/*.so; do
    name="$(basename "$so" .so)"
    directive=extension module="$name"
    case "$name" in xdebug) directive=zend_extension ;; opcache) directive=zend_extension module="Zend OPcache" ;; esac
    check "$name.so loads" "$PHP" -n -d "$directive=$so" -r "exit(extension_loaded('$module') ? 0 : 1);"
done

exit $fail
