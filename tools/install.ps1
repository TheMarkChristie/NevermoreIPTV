<#
.SYNOPSIS
    Installs or updates Nevermore IPTV on a Google TV over the home network, and can hand it a provider login.

.DESCRIPTION
    Once per TV: Settings > System > About, press OK on "Android TV OS build" seven times; then Settings > System >
    Developer options > USB debugging on. The TV asks to allow this PC the first time the script connects.

    The login is handed to the app through its Setup entry, which only adb can open. It is typed here (-AskLogin) or read
    from a .env file (-EnvFile with IPTV_XTREAM_URL, IPTV_XTREAM_USERNAME, IPTV_XTREAM_PASSWORD), and is never printed
    or saved by this script.

.EXAMPLE
    tools\install.ps1 -Tv 192.168.1.50
    tools\install.ps1 -Tv 192.168.1.50 -AskLogin
    tools\install.ps1 -Tv 192.168.1.50 -EnvFile .env -PlaybackTest
    tools\install.ps1 -Tv 192.168.1.50 -NoInstall -PlaybackTest -View platform
    tools\install.ps1 -Tv emulator-5554 -EnvFile .env -PlaybackTest      (an Android Studio emulator)
    tools\install.ps1 -Tv 192.168.1.50 -NoInstall -M3uUrl https://raw.githubusercontent.com/Free-TV/IPTV/master/playlist.m3u8 -SourceName Free-TV

    tools\install.ps1 -Tv 192.168.1.50 -NoInstall -VpnConfig $env:USERPROFILE\Downloads\wg-US-FREE-12.conf

    A source handed in replaces the source of the same name on the TV, else it is added. -VpnConfig hands in a
    WireGuard file from any VPN (Proton, Mullvad, Surfshark, Windscribe...) for a server outside the UK; its private key
    is never printed. The app can also take one from a phone: Settings > VPN > Add a WireGuard file.
#>
param(
    [Parameter(Mandatory = $true)] [string] $Tv,
    [string] $Apk = (Join-Path $PSScriptRoot '..\build\app\outputs\flutter-apk\app-release.apk'),
    [string] $EnvFile,
    [switch] $AskLogin,
    [string] $M3uUrl,
    [string] $GuideUrl,
    [string] $VpnConfig,
    [string] $SourceName,
    [switch] $NoInstall,
    [switch] $PlaybackTest,
    [ValidateSet('texture', 'platform')] [string] $View = 'texture'
)
$ErrorActionPreference = 'Stop'
$package = 'com.themarkchristie.nevermoreiptv'

function Find-Adb {
    $onPath = Get-Command adb -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    foreach ($candidate in @('C:\flutterdev\android-sdk\platform-tools\adb.exe',
                             "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe",
                             "$env:LOCALAPPDATA\NevermoreIPTV\platform-tools\adb.exe")) {
        if (Test-Path $candidate) { return $candidate }
    }
    # No Android tools on this PC: fetch Google's platform-tools.
    $dest = "$env:LOCALAPPDATA\NevermoreIPTV"
    New-Item -ItemType Directory -Force $dest | Out-Null
    $zip = Join-Path $dest 'platform-tools.zip'
    Write-Host 'Downloading Google platform-tools (adb)...'
    Invoke-WebRequest -UseBasicParsing 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip' -OutFile $zip
    Expand-Archive -Force $zip $dest
    Remove-Item $zip
    return "$dest\platform-tools\adb.exe"
}

# One argument for 'adb shell': each value single-quoted for the TV's shell. Windows PowerShell 5.1 does not escape
# double quotes inside an argument for a native program, so that is done here.
function Quote-Sh([string] $value) { "'" + ($value -replace "'", "'\''") + "'" }
function Invoke-AdbShell([string] $command) {
    $arg = $command
    if ($PSVersionTable.PSVersion.Major -lt 7 -or $PSNativeCommandArgumentPassing -eq 'Legacy') { $arg = $arg -replace '"', '\"' }
    & $script:adb -s $script:serial shell $arg
}

function Read-EnvFile([string] $path) {
    $values = @{}
    foreach ($line in Get-Content $path) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') { $values[$Matches[1]] = $Matches[2].Trim().Trim('"') }
    }
    $values
}

$script:adb = Find-Adb
$script:serial = if ($Tv -match ':\d+$' -or $Tv -match '^emulator-\d+$') { $Tv } else { "${Tv}:5555" }

if ($serial -notmatch '^emulator-') {
    Write-Host "> adb connect $serial"
    & $adb connect $serial | Write-Host
}
$state = (& $adb -s $serial get-state 2>&1) -join ' '
if ($state -notmatch '^device') {
    throw "The TV is not ready ($state). If it says unauthorized, accept 'Allow USB debugging' on the TV and run this again."
}
$model = (& $adb -s $serial shell getprop ro.product.model) -join ''
$android = (& $adb -s $serial shell getprop ro.build.version.release) -join ''
Write-Host "TV: $model, Android $android"

if (-not $NoInstall) {
    $apkPath = (Resolve-Path $Apk).Path
    Write-Host "> adb -s $serial install -r `"$apkPath`""
    & $adb -s $serial install -r $apkPath | Write-Host
    if ($LASTEXITCODE -ne 0) { throw 'The install failed (see above).' }
}

$login = $null
if ($EnvFile) {
    $envValues = Read-EnvFile $EnvFile
    $login = @{ url = $envValues['IPTV_XTREAM_URL']; username = $envValues['IPTV_XTREAM_USERNAME']; password = $envValues['IPTV_XTREAM_PASSWORD'] }
} elseif ($AskLogin) {
    $url = Read-Host 'Server address (for example http://host:8080)'
    $user = Read-Host 'Username'
    $secure = Read-Host 'Password' -AsSecureString
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
    $login = @{ url = $url; username = $user; password = $plain }
}
if ($login -and ($login.Values | Where-Object { -not $_ })) { throw 'The login is missing the server address, username or password.' }

if ($login -or $M3uUrl -or $VpnConfig -or $PlaybackTest) {
    $parts = @("am start -S -n $package/.Setup")
    $shown = @("am start -S -n $package/.Setup")
    if ($VpnConfig) {
        $conf = Get-Item $VpnConfig
        $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((Get-Content $conf.FullName -Raw)))
        $parts += "--es vpn_conf_b64 $b64 --es vpn_name $(Quote-Sh $conf.BaseName)"
        $shown += "--es vpn_conf_b64 '***' --es vpn_name $(Quote-Sh $conf.BaseName)"
    }
    if ($M3uUrl) {
        $name = if ($SourceName) { $SourceName } else { 'Playlist' }
        foreach ($pair in @(@('kind', 'm3u'), @('name', $name), @('url', $M3uUrl), @('guide', "$GuideUrl"))) {
            $parts += "--es $($pair[0]) $(Quote-Sh $pair[1])"
            $shown += "--es $($pair[0]) $(Quote-Sh $pair[1])"
        }
    } elseif ($login) {
        $name = if ($SourceName) { $SourceName } else { 'My provider' }
        foreach ($pair in @(@('kind', 'xtream'), @('name', $name), @('url', $login.url), @('username', $login.username), @('password', $login.password))) {
            $parts += "--es $($pair[0]) $(Quote-Sh $pair[1])"
            $shown += $(if ($pair[0] -in 'username', 'password') { "--es $($pair[0]) '***'" } else { "--es $($pair[0]) $(Quote-Sh $pair[1])" })
        }
    }
    if ($PlaybackTest) {
        $parts += '--ez autorun true'; $shown += '--ez autorun true'
        if ($View -eq 'platform') { $parts += '--es view platform'; $shown += '--es view platform' }
        & $adb -s $serial logcat -c
    }
    Write-Host "> adb -s $serial shell $($shown -join ' ')"
    Invoke-AdbShell ($parts -join ' ') | Write-Host
}

if ($PlaybackTest) {
    # The app prints "NVTEST ..." lines to the TV's log; follow them until it says done (about five minutes).
    Write-Host 'Playback test running on the TV. Results:'
    $seen = 0
    $deadline = (Get-Date).AddMinutes(12)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        $lines = @(& $adb -s $serial logcat -d -s flutter:I | Where-Object { $_ -match 'NVTEST ' } | ForEach-Object { ($_ -split 'NVTEST ', 2)[1] })
        for ($i = $seen; $i -lt $lines.Count; $i++) { Write-Host "  $($lines[$i])" }
        $seen = $lines.Count
        if ($lines | Where-Object { $_ -in 'done', 'stopped' }) { break }
    }
}
