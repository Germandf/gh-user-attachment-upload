[CmdletBinding()]
param(
    [string] $InstallDir = "$HOME\.dotnet\tools"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSCommandPath
$sourceScript = Join-Path $repoRoot 'gh-upload-image.ps1'
$targetScript = Join-Path $InstallDir 'gh-upload-image.ps1'
$targetCommand = Join-Path $InstallDir 'gh-upload-image.cmd'

if (-not (Test-Path -LiteralPath $sourceScript)) {
    throw "Source script not found: $sourceScript"
}

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Copy-Item -LiteralPath $sourceScript -Destination $targetScript -Force

$commandContent = @'
@echo off
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0gh-upload-image.ps1" %*
'@
Set-Content -LiteralPath $targetCommand -Value $commandContent -Encoding ASCII

$pathEntries = ($env:PATH -split ';') | Where-Object { $_ }
$isOnPath = $pathEntries | Where-Object {
    try {
        [System.IO.Path]::GetFullPath($_).TrimEnd('\') -ieq [System.IO.Path]::GetFullPath($InstallDir).TrimEnd('\')
    }
    catch {
        $false
    }
}

Write-Host "Installed gh-upload-image to $InstallDir"
if (-not $isOnPath) {
    Write-Warning "$InstallDir is not currently on PATH. Add it to PATH or invoke $targetCommand directly."
}
