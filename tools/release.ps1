<#
.SYNOPSIS
    Builds a Nevermore IPTV release: the house APK (with the house file, for this household's TVs) and the public APK
    (without it, the one the app's update check fetches from GitHub), and publishes the public one as a GitHub release.

.DESCRIPTION
    The public repository must never carry the house file (presets.json names the household's provider and sites), so
    the public APK is built with assets\house\presets.json moved aside, and the built APK is checked not to contain it.
    A house copy that updates itself from GitHub keeps its presets: the app keeps a copy in its data folder (0.7.3).

    Both APKs are signed with the same key (android\key.properties), which every installed copy requires of an update.

.EXAMPLE
    tools\release.ps1 -Version 0.7.4
    tools\release.ps1 -Version 0.7.4 -Publish -Notes "Guide files for the US and Canada; Enter a code; update check."

    -Publish needs the commit pushed to GitHub first and the gh CLI signed in (gh auth status). The release is tagged
    v<Version> on the current branch head and carries the public APK; the app compares the tag with its own version.
#>
param(
    [Parameter(Mandatory = $true)] [string] $Version,
    [switch] $Publish,
    [string] $Notes = '',
    [switch] $SkipHouse
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

function Invoke-ApkBuild([string] $what) {
    Write-Host "> flutter build apk --release   ($what)"
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
    if ($code -ne 0 -or -not (Test-Path $built)) { throw "the $what build failed" }
}

function Assert-NoHouseFile([string] $apk) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead((Resolve-Path $apk).Path)
    try {
        $hit = $zip.Entries | Where-Object { $_.FullName -like '*presets.json' }
        if ($hit) { throw "$apk contains $($hit.FullName): the public build must not carry the house file" }
    } finally { $zip.Dispose() }
}

# the public build first, so the house build is the one left in build\ (what tools\install.ps1 installs by default)
$aside = Join-Path $env:TEMP "presets-$([guid]::NewGuid()).json"
$moved = $false
try {
    if (Test-Path $house) { Move-Item $house $aside; $moved = $true }
    Invoke-ApkBuild 'public'
} finally {
    if ($moved) { Move-Item $aside $house -Force }
}
$public = "releases\NevermoreIPTV-$Version-public.apk"
Copy-Item $built $public -Force
Assert-NoHouseFile $public
$sha = (Get-FileHash $public -Algorithm SHA256).Hash.ToLower()
Write-Host "public APK: $public"
Write-Host "sha256: $sha"

if ((Test-Path $house) -and -not $SkipHouse) {
    Invoke-ApkBuild 'house'
    Copy-Item $built "releases\NevermoreIPTV-$Version.apk" -Force
    Write-Host "house APK: releases\NevermoreIPTV-$Version.apk"
}

if ($Publish) {
    $body = @($Notes, '', "sha256 of the APK: $sha") -join "`n"
    Write-Host "> gh release create v$Version $public"
    & gh release create "v$Version" $public --title "Nevermore IPTV $Version" --notes $body
    if ($LASTEXITCODE -ne 0) { throw 'gh release create failed (is the commit pushed, and gh signed in?)' }
}
