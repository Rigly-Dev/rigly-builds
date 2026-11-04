# Assembles a Rigly PHP package for Windows: the official windows.php.net NTS x64 build plus the
# PECL extension DLLs built by php/php-windows-builder, a php.ini-rigly, and a smoke test.
#
#   pwsh scripts/windows-package.ps1 -Version 8.4.27-1 -ZipUrl <official zip url> -Artifacts artifacts
#
# Output in dist/: php-<x.y.z>-windows-x64.zip (+ .sha256, .json)
param(
    [Parameter(Mandatory)] [string] $Version,      # windows.php.net version, e.g. 8.4.27-1
    [Parameter(Mandatory)] [string] $ZipUrl,
    [Parameter(Mandatory)] [string] $Artifacts,    # directory of downloaded extension artifacts
    [string] $Config = "windows-extensions.json",
    [string] $OutDir = "dist"
)
$ErrorActionPreference = "Stop"
$base = ($Version -split '-')[0]                   # 8.4.27
$minor = ($base -split '\.')[0..1] -join '.'       # 8.4
$name = "php-$base-windows-x64"
$pkg = Join-Path $OutDir $name
Remove-Item -Recurse -Force $pkg -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $pkg, "$pkg\licenses" | Out-Null

Write-Host "Downloading $ZipUrl"
Invoke-WebRequest -Uri $ZipUrl -OutFile "$env:TEMP\php.zip"
Expand-Archive -Path "$env:TEMP\php.zip" -DestinationPath $pkg -Force

# Extension artifacts: one directory per extension, named like php_imagick-3.8.1-8.4-nts-vs17-x86_64.zip,
# each containing a zip of the DLL, its dependency DLLs, config files and licenses.
$config = Get-Content $Config | ConvertFrom-Json
$built = @()
foreach ($artifact in Get-ChildItem -Directory $Artifacts) {
    if ($artifact.Name -notmatch "-$([regex]::Escape($minor))-nts-") { continue }
    $dir = $artifact
    $inner = Get-ChildItem -Path $artifact.FullName -Filter "*.zip" | Select-Object -First 1
    if ($inner) {
        $extracted = Join-Path $env:TEMP ("rigly-" + $artifact.Name)
        Expand-Archive -Path $inner.FullName -DestinationPath $extracted -Force
        $dir = Get-Item $extracted
    }
    $dll = Get-ChildItem -Path $dir.FullName -Recurse -Filter "php_*.dll" | Select-Object -First 1
    if (-not $dll) { Write-Warning "No extension DLL in $($dir.Name)"; continue }
    $ext = $dll.BaseName -replace '^php_', ''
    Copy-Item $dll.FullName "$pkg\ext\" -Force
    # Third-party DLLs (ImageMagick, zstd, ...) go next to php.exe so Windows can find them.
    Get-ChildItem -Path $dir.FullName -Recurse -Filter "*.dll" | Where-Object { $_.Name -notlike "php_*" } | ForEach-Object {
        if (-not (Test-Path "$pkg\$($_.Name)")) { Copy-Item $_.FullName $pkg }
    }
    if (Test-Path "$($dir.FullName)\config") {
        New-Item -ItemType Directory -Force "$pkg\imagemagick" | Out-Null
        Copy-Item "$($dir.FullName)\config\*" "$pkg\imagemagick\" -Force
    }
    New-Item -ItemType Directory -Force "$pkg\licenses\$ext" | Out-Null
    Get-ChildItem -Path $dir.FullName -File | Where-Object { $_.Name -match '^(LICEN[CS]E|COPYING|COPYRIGHT)' } |
        Copy-Item -Destination "$pkg\licenses\$ext\" -Force
    $built += $ext
}
Write-Host "Extension DLLs: $($built -join ', ')"
# Every configured extension (not skipped for this PHP version) must be present.
$wanted = $config.extensions | Where-Object { -not ($_.skip -and ($_.skip -contains $minor)) } | ForEach-Object { $_.name }
$missing = $wanted | Where-Object { $built -notcontains $_ }
if ($missing) { throw "Extension builds missing for PHP ${minor}: $($missing -join ', ')" }

# php.ini-rigly: everything useful enabled except debuggers/coverage (enable those when needed).
$core = "bz2 curl exif fileinfo ftp gd gettext gmp intl ldap mbstring mysqli openssl pdo_mysql pdo_pgsql pdo_sqlite pgsql soap sockets sodium sqlite3 tidy xsl zip" -split ' '
$ini = @(
    "; Rigly php.ini for PHP $base (Windows). Copy to php.ini.",
    "extension_dir = `"ext`"",
    "memory_limit = 512M", "upload_max_filesize = 512M", "post_max_size = 512M",
    "display_errors = On", "error_reporting = E_ALL", "",
    "; Bundled with PHP"
)
foreach ($ext in $core) { if (Test-Path "$pkg\ext\php_$ext.dll") { $ini += "extension=$ext" } }
if (Test-Path "$pkg\ext\php_opcache.dll") { $ini += "zend_extension=opcache" }
$ini += "", "; Added by Rigly"
foreach ($e in $config.extensions) {
    if ($built -notcontains $e.name) { continue }
    $directive = if ($e.zend) { "zend_extension" } else { "extension" }
    $prefix = if ($e.enable) { "" } else { ";" }
    $ini += "$prefix$directive=$($e.name)"
}
$ini += "", "[xdebug]", ";xdebug.mode=debug", ";xdebug.start_with_request=trigger", ";xdebug.client_port=9003"
$ini | Set-Content "$pkg\php.ini-rigly" -Encoding ascii

# ---- Smoke test ----
$php = "$pkg\php.exe"
$extDir = (Resolve-Path "$pkg\ext").Path
$env:MAGICK_CONFIGURE_PATH = "$pkg\imagemagick"
$fail = $false
function Check($label, [string[]] $phpArgs) {
    & $php -c "$pkg\php.ini-rigly" -d "extension_dir=$extDir" @phpArgs 2>&1 | Out-String | Set-Variable out
    if ($LASTEXITCODE -eq 0) { Write-Host "  ok  $label" } else { Write-Host "  FAIL $label`n$out"; $script:fail = $true }
}
Write-Host "Smoke testing $name"
Check "php runs" @("-v")
$expected = ($config.extensions | Where-Object { $_.enable -and ($built -contains $_.name) } | ForEach-Object { $_.name }) -join ','
Check "enabled extensions load ($expected)" @("-r", "foreach (explode(',', '$expected') as `$e) if (`$e && !extension_loaded(`$e)) { fwrite(STDERR, `"missing `$e`n`"); exit(1); }")
Check "pdo_sqlite is complete" @("-r", "`$p = new PDO('sqlite::memory:'); if (PHP_VERSION_ID >= 80400 && !class_exists('Pdo\\Sqlite')) exit(1); `$p->sqliteCreateFunction('t', fn(`$x) => `$x * 2, 1); exit(`$p->query('SELECT t(21)')->fetchColumn() == 42 ? 0 : 1);")
if ($built -contains "imagick") {
    Check "imagick renders" @("-r", "`$i = new Imagick('logo:'); `$i->setImageFormat('png'); exit(strlen(`$i->getImageBlob()) > 1000 ? 0 : 1);")
}
foreach ($e in $config.extensions | Where-Object { -not $_.enable -and ($built -contains $_.name) }) {
    $directive = if ($e.zend) { "zend_extension" } else { "extension" }
    Check "$($e.name) loads" @("-d", "$directive=$($e.name)", "-r", "exit(extension_loaded('$($e.name)') ? 0 : 1);")
}
if ($fail) { throw "Smoke test failed" }

# ---- Metadata + archive ----
$modules = & $php -c "$pkg\php.ini-rigly" -d "extension_dir=$extDir" -m | Where-Object { $_ -and $_ -notmatch '^\[' }
[ordered]@{
    php = $base
    build = $Version
    arch = "windows-x64"
    extensions = @($modules | Sort-Object -Unique)
    shared = @($config.extensions | Where-Object { -not $_.enable -and ($built -contains $_.name) } | ForEach-Object { $_.name })
    pecl = $built
    built_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
} | ConvertTo-Json | Set-Content "$pkg\BUILD.json" -Encoding utf8

$zip = Join-Path $OutDir "$name.zip"
Compress-Archive -Path "$pkg\*" -DestinationPath $zip -Force
(Get-FileHash $zip -Algorithm SHA256).Hash.ToLower() | Set-Content "$zip.sha256" -NoNewline -Encoding ascii
Copy-Item "$pkg\BUILD.json" (Join-Path $OutDir "$name.json")
Write-Host "Built $zip"
