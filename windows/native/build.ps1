<#
.SYNOPSIS
    Build system for the native Windows (Qt 6 / C++) Segmenter port.

.DESCRIPTION
    Resolves the MSVC and Qt toolchains, configures CMake, builds, and stages a
    runnable distribution: Qt runtime via windeployqt plus the LibVLC DLLs and
    plugin tree, which windeployqt knows nothing about.

.PARAMETER Configuration
    Release (default) or Debug.

.PARAMETER Clean
    Deletes the build directory before configuring.

.PARAMETER Run
    Launches the app once the build succeeds.
#>

[CmdletBinding()]
param(
    [ValidateSet('Release', 'Debug')]
    [string]$Configuration = 'Release',

    [switch]$Clean,

    [switch]$Run
)

$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$BuildDir = Join-Path $Root "build\$Configuration"
$DistDir = Join-Path $Root 'dist'
$VlcDir = Join-Path $Root 'third_party\vlc'

Write-Host '=== Segmenter Windows Native (Qt 6 / C++) Build ===' -ForegroundColor Cyan

# --- MSVC -------------------------------------------------------------------
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) {
    throw "vswhere.exe not found. Install Visual Studio 2022 Build Tools with the C++ workload."
}

$vsPath = & $vswhere -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath
if (-not $vsPath) {
    throw 'No Visual Studio installation with the MSVC x64 toolset was found.'
}
Write-Host "MSVC:  $vsPath" -ForegroundColor DarkGray

# vcvars64.bat exports its environment into the calling shell only; run it in a
# child cmd and import the resulting variables so cl.exe, the Windows SDK and
# the linker are all resolvable from this PowerShell session.
$vcvars = Join-Path $vsPath 'VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path $vcvars)) {
    throw "vcvars64.bat not found at $vcvars"
}

cmd /c "`"$vcvars`" >nul 2>&1 && set" | ForEach-Object {
    if ($_ -match '^([^=]+)=(.*)$') {
        Set-Item -Path "env:$($matches[1])" -Value $matches[2] -ErrorAction SilentlyContinue
    }
}

# --- Qt ---------------------------------------------------------------------
$QtRoot = $env:SEGMENTER_QT_ROOT
if (-not $QtRoot) {
    $candidates = @()
    foreach ($base in @('C:\Qt', 'D:\Qt', (Join-Path $env:USERPROFILE 'Qt'))) {
        if (Test-Path $base) {
            $candidates += Get-ChildItem $base -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^6\.\d+' } |
                ForEach-Object { Join-Path $_.FullName 'msvc2022_64' } |
                Where-Object { Test-Path (Join-Path $_ 'lib\cmake\Qt6\Qt6Config.cmake') }
        }
    }
    # Newest first, so a machine with several Qt versions picks the latest.
    $QtRoot = $candidates | Sort-Object -Descending | Select-Object -First 1
}

if (-not $QtRoot -or -not (Test-Path $QtRoot)) {
    throw @"
Qt 6 (msvc2022_64) not found.
Install it with:  python -m aqt install-qt windows desktop 6.8.3 win64_msvc2022_64 --outputdir C:\Qt
Or set SEGMENTER_QT_ROOT to an existing Qt msvc2022_64 directory.
"@
}
Write-Host "Qt:    $QtRoot" -ForegroundColor DarkGray

# --- CMake ------------------------------------------------------------------
if (-not (Get-Command cmake -ErrorAction SilentlyContinue)) {
    $cmakeBin = 'C:\Program Files\CMake\bin'
    if (Test-Path (Join-Path $cmakeBin 'cmake.exe')) {
        $env:PATH = "$cmakeBin;$env:PATH"
    } else {
        throw 'cmake not found. Install with: winget install Kitware.CMake'
    }
}

# Ninja: winget's copy, else the one bundled with the VS CMake component.
if (-not (Get-Command ninja -ErrorAction SilentlyContinue)) {
    $ninjaCandidates = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'),
        (Join-Path $vsPath 'Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja')
    )
    foreach ($candidate in $ninjaCandidates) {
        if (Test-Path (Join-Path $candidate 'ninja.exe')) {
            $env:PATH = "$candidate;$env:PATH"
            break
        }
    }
}
$Generator = if (Get-Command ninja -ErrorAction SilentlyContinue) { 'Ninja' } else { 'NMake Makefiles' }
Write-Host "Gen:   $Generator" -ForegroundColor DarkGray

# --- LibVLC -----------------------------------------------------------------
if (-not (Test-Path (Join-Path $VlcDir 'sdk\include\vlc\vlc.h'))) {
    throw @"
LibVLC SDK missing from $VlcDir.
Fetch it with:
  Invoke-WebRequest https://www.nuget.org/api/v2/package/VideoLAN.LibVLC.Windows/3.0.21 -OutFile libvlc.zip
then expand build/x64 into third_party/vlc as sdk/include, sdk/lib, plugins and the two DLLs.
"@
}

# --- Configure & build ------------------------------------------------------
if ($Clean -and (Test-Path $BuildDir)) {
    Write-Host 'Cleaning build directory...' -ForegroundColor Yellow
    Remove-Item -Recurse -Force $BuildDir
}

Write-Host "Configuring ($Configuration)..." -ForegroundColor Green
cmake -S $Root -B $BuildDir -G $Generator `
    "-DCMAKE_BUILD_TYPE=$Configuration" `
    "-DCMAKE_PREFIX_PATH=$QtRoot" `
    "-DVLC_SDK_DIR=$VlcDir"
if ($LASTEXITCODE -ne 0) { throw "CMake configure failed with exit code $LASTEXITCODE" }

Write-Host 'Building...' -ForegroundColor Green
cmake --build $BuildDir --config $Configuration --parallel
if ($LASTEXITCODE -ne 0) { throw "Build failed with exit code $LASTEXITCODE" }

# --- Stage the distribution -------------------------------------------------
$exe = Join-Path $BuildDir 'bin\Segmenter.exe'
if (-not (Test-Path $exe)) {
    throw "Build reported success but $exe is missing."
}

Write-Host 'Staging distribution...' -ForegroundColor Green

# A running instance holds its Qt and LibVLC DLLs open, which makes the staging
# wipe below fail with an access-denied part-way through.
Get-Process Segmenter -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host "Stopping running Segmenter (PID $($_.Id))..." -ForegroundColor Yellow
    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Milliseconds 500

# Everything except the plugin tree is rebuilt from scratch. The plugins are
# preserved because LibVLC writes a generated plugins.dat into that folder on
# first run, and rebuilding it costs ~20 s of a blank window on the next launch.
if (Test-Path $DistDir) {
    Get-ChildItem $DistDir -Force |
        Where-Object { $_.Name -ne 'plugins' } |
        Remove-Item -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $DistDir | Out-Null
Copy-Item $exe $DistDir -Force

& (Join-Path $QtRoot 'bin\windeployqt.exe') `
    --$($Configuration.ToLower()) `
    --no-translations --no-system-d3d-compiler --no-opengl-sw `
    (Join-Path $DistDir 'Segmenter.exe')
if ($LASTEXITCODE -ne 0) { throw "windeployqt failed with exit code $LASTEXITCODE" }

# LibVLC resolves its plugin tree relative to the DLL at runtime, so the whole
# folder has to travel next to the executable.
Copy-Item (Join-Path $VlcDir 'libvlc.dll') $DistDir -Force
Copy-Item (Join-Path $VlcDir 'libvlccore.dll') $DistDir -Force
if (-not (Test-Path (Join-Path $DistDir 'plugins'))) {
    Copy-Item (Join-Path $VlcDir 'plugins') (Join-Path $DistDir 'plugins') -Recurse -Force
}
foreach ($optional in @('hrtfs', 'lua')) {
    $path = Join-Path $VlcDir $optional
    if (Test-Path $path) { Copy-Item $path (Join-Path $DistDir $optional) -Recurse -Force }
}

$sizeMb = [math]::Round(((Get-ChildItem $DistDir -Recurse | Measure-Object -Property Length -Sum).Sum / 1MB), 1)
Write-Host "=== Build complete: $DistDir ($sizeMb MB) ===" -ForegroundColor Cyan

if ($Run) {
    Write-Host 'Launching Segmenter...' -ForegroundColor Green
    Start-Process (Join-Path $DistDir 'Segmenter.exe')
}
