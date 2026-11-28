#Requires -Version 7
# Runs the app's end-to-end self-test (App\SelfTest.cs) in a throwaway data folder, writes the report,
# and fails if the core, refresh, or rendering didn't work. Used by CI after build.ps1.
param(
    # The app to test: a build's or a publish's NetNewsWire.exe. By default, the newest build.
    [string] $AppPath,
    [string] $Feed = 'https://netnewswire.blog/feed.xml',
    [string] $Report = (Join-Path $PSScriptRoot 'selftest-report.json'),
    [int] $TimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'
# Not a Native AOT publish's intermediate native\ copy, which lacks the Windows App SDK's DLLs.
$lastBuild = Join-Path $PSScriptRoot 'App\bin\LastBuild.txt'
if (-not $AppPath -and (Test-Path $lastBuild)) { $AppPath = (Get-Content $lastBuild -Raw).Trim() }
$exe = if ($AppPath) { Get-Item $AppPath } else {
    Get-ChildItem (Join-Path $PSScriptRoot 'App\bin') -Recurse -Filter 'NetNewsWire.exe' |
        Where-Object { $_.FullName -notmatch '\\(AppPackages|native)\\' } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}
if (-not $exe) { throw 'NetNewsWire.exe not found: run build.ps1 first.' }

# A data folder of its own, so the test never touches a real one.
$data = Join-Path ([IO.Path]::GetTempPath()) "nnw-selftest-$([Guid]::NewGuid())"
New-Item -ItemType Directory $data | Out-Null
$env:LOCALAPPDATA = $data
Remove-Item $Report -ErrorAction SilentlyContinue

$process = Start-Process $exe.FullName -ArgumentList '--selftest', $Feed, $Report -PassThru
if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
    $process.Kill()
    throw "The self-test didn't finish in $TimeoutSeconds seconds."
}
if (-not (Test-Path $Report)) { throw "No self-test report (exit code $($process.ExitCode))." }
$result = Get-Content $Report -Raw | ConvertFrom-Json
Get-Content $Report

$failures = @()
if ($process.ExitCode -ne 0) { $failures += "exit code $($process.ExitCode)" }
if ($result.PSObject.Properties['exception']) { $failures += "exception: $($result.exception)" }
if ($result.refreshed -ne $true) { $failures += 'the feed did not refresh' }
if ($result.articleCount -lt 1) { $failures += 'no articles' }
if ($result.webView2Rendered -ne $true) { $failures += 'WebView2 did not render the article' }
foreach ($i in 1..20) { try { Remove-Item -Recurse -Force $data -ErrorAction Stop; break } catch { Start-Sleep -Milliseconds 500 } }
if ($failures) { throw "Self-test failed: $($failures -join '; ')" }
'Self-test passed.'
