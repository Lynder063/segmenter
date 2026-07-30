# Resolve directory of this script
$PSScriptRoot = Split-Path -Parent -Path $MyInvocation.MyCommand.Path

Write-Host "=== Segmenter Windows 11 Build System ===" -ForegroundColor Cyan

# windows/dotnet -> windows -> repo root.
$DotnetPath = "$PSScriptRoot\..\..\.dotnet\dotnet.exe"
if (-not (Test-Path $DotnetPath)) {
    Write-Error "Dotnet SDK not found at $DotnetPath. Please ensure .dotnet is installed in the workspace."
    Exit 1
}

# Terminate any running Segmenter processes to prevent file lock during publish
Stop-Process -Name "Segmenter" -Force -ErrorAction SilentlyContinue

Write-Host "Restoring and Publishing Segmenter in Release mode for Windows x64..." -ForegroundColor Green

& $DotnetPath publish "$PSScriptRoot\Segmenter\Segmenter.csproj" `
    -c Release `
    -r win-x64 `
    --self-contained true `
    -p:PublishSingleFile=true `
    -p:PublishReadyToRun=true `
    -p:IncludeNativeLibrariesForSelfExtract=true `
    -o "$PSScriptRoot\dist"

# Copy libvlc folder to dist because single-file publish doesn't export native folder structures properly
$libvlcSource = "$PSScriptRoot\Segmenter\bin\Release\net8.0-windows\win-x64\libvlc"
$libvlcTarget = "$PSScriptRoot\dist\libvlc"
if (Test-Path $libvlcSource) {
    if (-not (Test-Path $libvlcTarget)) {
        New-Item -ItemType Directory -Path $libvlcTarget -Force | Out-Null
    }
    Copy-Item -Path "$libvlcSource\*" -Destination $libvlcTarget -Recurse -Force
}

if ($LASTEXITCODE -eq 0) {
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "Build Successful!" -ForegroundColor Green
    Write-Host "Standalone executable generated at:" -ForegroundColor Green
    Write-Host "$PSScriptRoot\dist\Segmenter.exe" -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Green
} else {
    Write-Error "Build Failed with exit code $LASTEXITCODE"
    Exit $LASTEXITCODE
}
