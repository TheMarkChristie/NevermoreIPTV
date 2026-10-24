<#
.SYNOPSIS
    Builds a Nevermore IPTV release APK and publishes it as a GitHub release, which every installed copy's
    Settings > Update finds.

.DESCRIPTION
    One APK for everyone. When assets\house\presets.json is present (the household's preset and Web sites, built from
    docs\House-Channels.md by tools\make_house_presets.py and kept out of the repository's source), it is built in and so
    travels inside the public APK; Mark's decision of 24 Oct 2026 ("I still want that in the public one") - the file
    holds the provider's server address, the code and the sites, never a login.

    The APK is signed with the key in android\key.properties, which every installed copy requires of an update.

.EXAMPLE
    tools\release.ps1 -Version 0.7.4
    tools\release.ps1 -Version 0.7.4 -Publish -Notes "Guide files for the US and Canada; Enter a code; the update check."

    -Publish needs the commit pushed to GitHub first and the gh CLI signed in (gh auth status). The release is tagged
    v<Version> on the pushed head and carries the APK; the app compares the tag with its own version.
#>
param(
    [Parameter(Mandatory = $true)] [string] $Version,
    [switch] $Publish,
    [string] $Notes = ''
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $root

$pubspec = Get-Content pubspec.yaml | Where-Object { $_ -match '^version:' }
if ($pubspec -notmatch "^version:\s*$([regex]::Escape($Version))\+") { throw "pubspec.yaml says '$pubspec', not $Version" }
if (-not (Test-Path android\key.properties)) { throw 'android\key.properties is missing: the build would be signed with the debug key' }

$flutter = if (Get-Command flutter -ErrorAction SilentlyContinue) { 'flutter' } else { 'C:\flutterdev\flutter\bin\flutter.bat' }
if (-not $env:JAVA_HOME -and (Test-Path 'C:\Program Files\Eclipse Adoptium\jdk-17.0.20.8-hotspot')) {
    $env:JAVA_HOME = 'C:\Program Files\Eclipse Adoptium\jdk-17.0.20.8-hotspot'
}
New-Item -ItemType Directory -Force releases | Out-Null
$built = 'build\app\outputs\flutter-apk\app-release.apk'
$house = 'assets\house\presets.json'
Write-Host $(if (Test-Path $house) { 'house file: built in' } else { 'house file: none (no preset, no Web category in this build)' })

Write-Host '> flutter build apk --release'
# stderr merged and errors non-terminating for the call: Gradle's warnings on stderr would otherwise stop the script
# (PowerShell 5.1 treats a native program's stderr as errors when the output is piped)
$prev = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & $flutter build apk --release 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match 'Built|error:|FAILURE' } | Write-Host
    $code = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $prev
}
if ($code -ne 0 -or -not (Test-Path $built)) { throw 'the build failed' }

$apk = "releases\NevermoreIPTV-$Version.apk"
Copy-Item $built $apk -Force
$sha = (Get-FileHash $apk -Algorithm SHA256).Hash.ToLower()
Write-Host "APK: $apk"
Write-Host "sha256: $sha"

if ($Publish) {
    $body = @($Notes, '', "sha256 of the APK: $sha") -join "`n"
    Write-Host "> gh release create v$Version $apk"
    & gh release create "v$Version" $apk --title "Nevermore IPTV $Version" --notes $body
    if ($LASTEXITCODE -ne 0) { throw 'gh release create failed (is the commit pushed, and gh signed in?)' }
}
