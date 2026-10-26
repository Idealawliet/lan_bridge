[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Push-Location $projectRoot
try {
    & flutter pub get --enforce-lockfile
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
    # App-local VC++ runtime lets a clean Windows machine run the client.
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    $visualStudio = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($LASTEXITCODE -ne 0 -or -not $visualStudio) { throw 'Cannot locate Visual Studio C++ runtime' }
    $runtime = Get-ChildItem (Join-Path $visualStudio 'VC/Redist/MSVC') -Directory |
        Sort-Object Name -Descending |
        ForEach-Object { Join-Path $_.FullName 'x64/Microsoft.VC143.CRT' } |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $runtime) { throw 'Visual C++ x64 redistributable DLLs are missing' }
    Copy-Item (Join-Path $runtime '*.dll') $bundleDirectory -Force
    $distDirectory = Join-Path $projectRoot 'dist'
    New-Item -ItemType Directory -Path $distDirectory -Force | Out-Null
    $archive = Join-Path $distDirectory "lan-bridge-windows-x64-$appVersion-unsigned.zip"
    Compress-Archive -Path (Join-Path $bundleDirectory '*') -DestinationPath $archive -Force
    $hash = (Get-FileHash -Algorithm SHA256 $archive).Hash.ToLowerInvariant()
    "$hash  $(Split-Path -Leaf $archive)" | Set-Content -Encoding ascii "$archive.sha256"
    $compiler = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6/ISCC.exe'
    if (-not (Test-Path $compiler)) {
        $command = Get-Command ISCC.exe -ErrorAction SilentlyContinue
        if ($command) { $compiler = $command.Source }
        else { throw 'Inno Setup 6 is required to create the Windows EXE installer.' }
    }
    & $compiler "/DAppVersion=$appVersion" "/DBundleDirectory=$bundleDirectory" "/DOutputDirectory=$distDirectory" (Join-Path $PSScriptRoot 'windows-installer.iss')
    if ($LASTEXITCODE -ne 0) { throw 'Windows installer build failed' }
    $installer = Join-Path $distDirectory "lan-bridge-windows-x64-$appVersion-setup-unsigned.exe"
    $installerHash = (Get-FileHash -Algorithm SHA256 $installer).Hash.ToLowerInvariant()
    "$installerHash  $(Split-Path -Leaf $installer)" | Set-Content -Encoding ascii "$installer.sha256"
    Write-Host "Created $archive"
    Write-Host "Created $installer"
    Write-Host 'Distribution signing is not configured. Keep all DLLs and the data directory with the EXE.'
} finally {
    Pop-Location
}
