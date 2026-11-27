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
# Any host's dumpbin reads any architecture's DLLs; ARM64 machines have HostARM64 rather than Hostx64.
$dumpbin = & $vswhere -latest -products * -find 'VC\Tools\MSVC\**\bin\Host*\*\dumpbin.exe' | Select-Object -First 1
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

$project = Join-Path $root 'App\NetNewsWire.Windows.csproj'
$runtimeIdentifier = if ($Platform -eq 'ARM64') { 'win-arm64' } else { 'win-x64' }
$common = @("-c", $Configuration, "-p:Platform=$Platform", "-p:NetNewsWireCoreDir=$coreDir\", "-p:SwiftRuntimeDir=$swiftRuntimeDir\")
$packageDir = Join-Path $root 'App\AppPackages\'
# Unsigned: sign it for distribution (signtool, winapp sign, or Azure Trusted Signing), or trust a
# development certificate and sign it with that for testing.
$packaging = @('-p:WindowsPackageType=MSIX', '-p:GenerateAppxPackageOnBuild=true', '-p:AppxPackageSigningEnabled=false', '-p:AppxBundle=Never', "-p:AppxPackageDir=$packageDir")

if ($Configuration -eq 'Release') {
    # Release: Native AOT. No JIT and no managed assemblies to load: about half the cold start of the
    # JIT build, and a smaller package. The MSIX, if asked for, packages this publish.
    $publishArgs = $common + @('-r', $runtimeIdentifier, '-p:PublishAot=true')
    if ($Package) { $publishArgs += $packaging }
    dotnet publish $project @publishArgs
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed ($LASTEXITCODE)" }
    $appPath = Get-ChildItem (Join-Path $root "App\bin\$Platform\Release") -Recurse -Filter 'NetNewsWire.exe' | Where-Object { $_.FullName -match '\\publish\\' } | Select-Object -First 1 -ExpandProperty FullName
}
else {
    # Debug: a JIT build, for quick turnaround.
    dotnet build $project @common
    if ($LASTEXITCODE -ne 0) { throw "dotnet build failed ($LASTEXITCODE)" }
    if ($Package) {
        dotnet build $project @common @packaging
        if ($LASTEXITCODE -ne 0) { throw "MSIX packaging failed ($LASTEXITCODE)" }
    }
    $appPath = Get-ChildItem (Join-Path $root "App\bin\$Platform\Debug") -Recurse -Filter 'NetNewsWire.exe' | Where-Object { $_.FullName -notmatch '\\(publish|native|AppPackages)\\' } | Select-Object -First 1 -ExpandProperty FullName
}

# Where the app is, for selftest.ps1 and CI.
Set-Content (Join-Path $root 'App\bin\LastBuild.txt') $appPath
Write-Host "App: $appPath"
if ($Package) {
    Get-ChildItem $packageDir -Recurse -Filter '*.msix' | ForEach-Object { Write-Host "Package: $($_.FullName) ($([Math]::Round($_.Length / 1MB)) MB)" }
}
