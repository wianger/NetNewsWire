#Requires -Version 7
# Builds NetNewsWire for Windows: the Swift core DLL, then the WinUI 3 app.
# Requires: Swift 6.4+ (official installer: winget install Swift.Toolchain), Visual Studio Build Tools (MSVC + Windows SDK), .NET 10 SDK.

param(
    [ValidateSet('x64', 'ARM64')] [string] $Platform = 'x64',
    [ValidateSet('Debug', 'Release')] [string] $Configuration = 'Debug'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = $PSScriptRoot
$repo = Split-Path $root -Parent
$triple = if ($Platform -eq 'ARM64') { 'aarch64-unknown-windows-msvc' } else { 'x86_64-unknown-windows-msvc' }

# Generate the gyb sources, as buildscripts/updateSecrets.sh does on the Mac: SecretKey.swift gets
# the API keys from environment variables (CI secrets), or empty values without them.
# The embedded Python that comes with Swift is enough; its ._pth file keeps the script's folder
# off sys.path, so run gyb.py itself rather than the buildscripts/gyb wrapper.
# Skip the Microsoft Store stub in WindowsApps, which opens the Store instead of running Python.
$python = Get-Command python -All -ErrorAction SilentlyContinue | Where-Object { $_.Source -notlike '*\WindowsApps\*' } | Select-Object -First 1 -ExpandProperty Source
if (-not $python) {
    $python = Get-ChildItem "$env:LOCALAPPDATA\Programs\Swift\Python-*\usr\bin\python.exe" -ErrorAction SilentlyContinue | Select-Object -Last 1 -ExpandProperty FullName
}
if (-not $python) { throw 'Python not found: install it, or the Swift toolchain, which includes one.' }
# Skip .build: SwiftPM checkouts (swift-crypto) carry their own, already generated, templates.
Get-ChildItem (Join-Path $repo 'Modules') -Recurse -Filter '*.gyb' | Where-Object { $_.FullName -notmatch '\\\.build\\' } | ForEach-Object {
    $output = $_.FullName -replace '\.gyb$', ''
    Write-Host "Generating $output"
    & $python (Join-Path $repo 'buildscripts\gyb.py') --line-directive '' -o $output $_.FullName
    if ($LASTEXITCODE -ne 0) { throw "gyb failed for $($_.FullName) ($LASTEXITCODE)" }
}

Push-Location (Join-Path $root 'Core')
try {
    $swiftArgs = @('-c', 'release', '--triple', $triple)
    swift build @swiftArgs
    if ($LASTEXITCODE -ne 0) { throw "swift build failed ($LASTEXITCODE)" }
    $coreDir = (swift build @swiftArgs --show-bin-path | Select-Object -Last 1).Trim()
}
finally {
    Pop-Location
}

dotnet build (Join-Path $root 'App\NetNewsWire.Windows.csproj') -c $Configuration -p:Platform=$Platform "-p:NetNewsWireCoreDir=$coreDir\"
if ($LASTEXITCODE -ne 0) { throw "dotnet build failed ($LASTEXITCODE)" }
