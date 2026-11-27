#Requires -Version 7
# Builds NetNewsWire for Windows: the Swift core DLL, then the WinUI 3 app.
# Requires: Swift 6.4+ (official installer: winget install Swift.Toolchain), Visual Studio Build Tools (MSVC + Windows SDK), .NET 10 SDK.

param(
    [ValidateSet('x64', 'ARM64')] [string] $Platform = 'x64',
    [ValidateSet('Debug', 'Release')] [string] $Configuration = 'Debug',
    # Also build the MSIX package (App\Package.appxmanifest), unsigned, into App\AppPackages.
    [switch] $Package
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

# The Swift runtime DLLs the core uses, so the app carries its own and runs where Swift isn't installed.
# Found by following the core DLLs' imports (dumpbin /dependents) into the runtime folder, so only what's
# used is copied: the Visual C++ runtime DLLs Swift needs come along, and the rest (FoundationXML, the
# Swift test and regex libraries the core doesn't link) doesn't.
$runtimeDir = $env:Path -split ';' | Where-Object { $_ -and (Test-Path (Join-Path $_ 'swiftCore.dll')) } | Select-Object -First 1
if (-not $runtimeDir) { throw 'The Swift runtime (swiftCore.dll) is not on PATH.' }
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$dumpbin = & $vswhere -latest -products * -find 'VC\Tools\MSVC\**\bin\Hostx64\x64\dumpbin.exe' | Select-Object -First 1
if (-not $dumpbin) { throw 'dumpbin not found: install the Visual Studio Build Tools C++ workload.' }
$swiftRuntimeDir = Join-Path $root "App\obj\SwiftRuntime\$Platform"
Remove-Item -Recurse -Force $swiftRuntimeDir -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $swiftRuntimeDir | Out-Null
$pending = [System.Collections.Generic.Queue[string]]::new()
Get-ChildItem $coreDir -Filter '*.dll' | ForEach-Object { $pending.Enqueue($_.FullName) }
$copied = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
while ($pending.Count -gt 0) {
    $dll = $pending.Dequeue()
    foreach ($line in & $dumpbin /nologo /dependents $dll) {
        if ($line -match '^\s+(\S+\.dll)\s*$') {
            $name = $Matches[1]
            $source = Join-Path $runtimeDir $name
            if ((Test-Path $source) -and $copied.Add($name)) {
                Copy-Item $source $swiftRuntimeDir
                $pending.Enqueue($source)
            }
        }
    }
}
Write-Host "Swift runtime: $($copied.Count) DLLs from $runtimeDir"

dotnet build (Join-Path $root 'App\NetNewsWire.Windows.csproj') -c $Configuration -p:Platform=$Platform "-p:NetNewsWireCoreDir=$coreDir\" "-p:SwiftRuntimeDir=$swiftRuntimeDir\"
if ($LASTEXITCODE -ne 0) { throw "dotnet build failed ($LASTEXITCODE)" }

if ($Package) {
    # Unsigned: sign it for distribution (signtool, or Azure Trusted Signing), or install it on a
    # Developer Mode machine for testing.
    $packageDir = Join-Path $root 'App\AppPackages\'
    dotnet build (Join-Path $root 'App\NetNewsWire.Windows.csproj') -c $Configuration -p:Platform=$Platform "-p:NetNewsWireCoreDir=$coreDir\" "-p:SwiftRuntimeDir=$swiftRuntimeDir\" `
        -p:WindowsPackageType=MSIX -p:GenerateAppxPackageOnBuild=true -p:AppxPackageSigningEnabled=false -p:AppxBundle=Never "-p:AppxPackageDir=$packageDir"
    if ($LASTEXITCODE -ne 0) { throw "MSIX packaging failed ($LASTEXITCODE)" }
    Get-ChildItem $packageDir -Recurse -Filter '*.msix' | ForEach-Object { Write-Host "Package: $($_.FullName) ($([Math]::Round($_.Length / 1MB)) MB)" }
}
