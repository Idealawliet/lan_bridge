[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Push-Location $projectRoot
try {
    & flutter pub get
    if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed' }
    & flutter build windows --release
    if ($LASTEXITCODE -ne 0) { throw 'Windows release build failed' }

    $versionLine = Get-Content 'pubspec.yaml' | Where-Object { $_ -match '^version:\s*' } | Select-Object -First 1
    if ($versionLine -notmatch '^version:\s*([0-9]+\.[0-9]+\.[0-9]+)') {
        throw 'Cannot read package version from pubspec.yaml'
    }
    $appVersion = $Matches[1]
    $bundleDirectory = Join-Path $projectRoot 'build/windows/x64/runner/Release'
    if (-not (Test-Path (Join-Path $bundleDirectory 'lan_bridge.exe'))) {
        throw "Windows application not found in $bundleDirectory"
    }
    if (-not (Test-Path (Join-Path $bundleDirectory 'data'))) {
        throw 'Flutter data directory missing; refusing to package an incomplete client'
    }
    $distDirectory = Join-Path $projectRoot 'dist'
    New-Item -ItemType Directory -Path $distDirectory -Force | Out-Null
    $archive = Join-Path $distDirectory "lan-bridge-windows-x64-$appVersion-unsigned.zip"
    Compress-Archive -Path (Join-Path $bundleDirectory '*') -DestinationPath $archive -Force
    $hash = (Get-FileHash -Algorithm SHA256 $archive).Hash.ToLowerInvariant()
    "$hash  $(Split-Path -Leaf $archive)" | Set-Content -Encoding ascii "$archive.sha256"
    Write-Host "Created $archive"
    Write-Host 'Distribution signing is not configured. Keep all DLLs and the data directory with the EXE.'
} finally {
    Pop-Location
}
