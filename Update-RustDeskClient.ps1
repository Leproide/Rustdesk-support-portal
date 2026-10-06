<#
.NOTES
    RustDesk Client Updater - Windows (PowerShell)
    Version: 2.0.0
    Author:  https://github.com/Leproide

    Copyright (C) 2026  https://github.com/Leproide

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.

    Exit codes:
        0  Success (updated, already up to date, or another run in progress)
        1  Runtime error (network, verification, file replacement, ...)
        2  Configuration error (invalid or missing parameters)
        3  Updated, but some platforms were skipped (asset not found)

    Compatible with Windows PowerShell 5.1 and PowerShell 7+.

.SYNOPSIS
    Publishes the latest RustDesk clients for Windows, macOS and Linux,
    preconfigured (Windows) or configurable (macOS/Linux) for your own server.

.DESCRIPTION
    RustDesk reads the self-hosted server configuration from the executable
    file name, but only on Windows:

        rustdesk-host=rd.example.com,key=<public-key>[,relay=<relay>],.exe

    macOS and Linux clients cannot be preconfigured through the file name.
    They are configured by importing a server configuration string
    (Settings > Network > ID/Relay Server > "Import server config") or with
    "rustdesk --config <string>" (installed client, root).

    For every new stable release this script:

      1. Downloads the selected platform assets from GitHub.
      2. Verifies size, SHA-256 digest (when published by GitHub), file
         signature (magic bytes) and, for Windows executables, Authenticode.
      3. Backs up the previously published files.
      4. Publishes the files under stable names in TargetDir; the Windows
         executables get the server configuration in their file name.
      5. Writes a JSON manifest (rustdesk.json) describing the published files
         and the server configuration, used by the download page (web/index.html).
      6. Optionally appends a line to a public update log.

    State, technical log and backups are kept in StateDir, outside TargetDir.

.PARAMETER TargetDir
    Directory where the clients are published (e.g. a web server folder).

.PARAMETER ServerHost
    RustDesk ID server (hbbs) host name or IP.

.PARAMETER Key
    RustDesk server public key (content of id_ed25519.pub).

.PARAMETER RelayServer
    Optional relay server (hbbr), e.g. "relay.example.com" or
    "relay.example.com:21117". When empty, the macOS/Linux configuration uses
    the ID server host as relay, and the Windows file name omits it (RustDesk
    then uses the relay announced by the ID server, normally the same host).

.PARAMETER ApiServer
    Optional API server URL (RustDesk Server Pro / compatible API servers).

.PARAMETER Platforms
    Platforms to publish. Default: windows-x64, macos-arm64, macos-x64,
    linux-x64-deb, linux-x64-rpm, linux-x64-appimage.
    Also available: windows-arm64, linux-arm64-deb, linux-arm64-rpm,
    linux-x64-suse-rpm, linux-arm64-suse-rpm, linux-arm64-appimage. Accepts an array or a comma-separated string.

.PARAMETER NameStyle
    How the server configuration is embedded in Windows file names:
      Auto    - Plain when all values are file-name safe, otherwise Encoded (default)
      Plain   - rustdesk-host=<host>,key=<key>[,relay=<relay>][,api=<api>],.exe
      Encoded - rustdesk--<encoded-config>--.exe
    Values containing characters invalid in Windows file names (for example
    ":" in "relay.example.com:21117", or "/" in a key or URL) require Encoded.

.PARAMETER Repository
    GitHub repository in "owner/name" form. Default: rustdesk/rustdesk.

.PARAMETER StateDir
    Directory for state, technical log and backups. Default: script folder.

.PARAMETER KeepBackups
    Number of previous releases to keep (all platforms of a release are kept
    together). 0 disables backups. Default: 1.

.PARAMETER WriteUpdateLog
    Append a line to <TargetDir>\<UpdateLogName> after each update.
    Enabled by default; disable with -WriteUpdateLog:$false.

.PARAMETER UpdateLogName
    File name of the public update log. Default: update.log.

.PARAMETER ManifestName
    File name of the JSON manifest read by the download page. Default: rustdesk.json.

.PARAMETER RequireValidSignature
    Abort if a Windows executable has no valid Authenticode signature.
    By default an invalid or missing signature is only logged.

.PARAMETER Force
    Download and publish even if nothing changed.

.EXAMPLE
    .\Update-RustDeskClient.ps1 -TargetDir 'D:\www\support' -ServerHost 'rd.example.com' -Key 'ABCDEF...='

.EXAMPLE
    .\Update-RustDeskClient.ps1 -TargetDir 'D:\www\support' -ServerHost 'rd.example.com' -Key 'ABCDEF...=' -RelayServer 'relay.example.com' -Platforms windows-x64,macos-arm64,macos-x64,linux-x64-deb

.LINK
    https://github.com/Leproide
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$TargetDir,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ServerHost,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Key,

    [string]$RelayServer = '',

    [string]$ApiServer = '',

    [string[]]$Platforms = @('windows-x64', 'macos-arm64', 'macos-x64', 'linux-x64-deb', 'linux-x64-rpm', 'linux-x64-appimage'),

    [ValidateSet('Auto', 'Plain', 'Encoded')]
    [string]$NameStyle = 'Auto',

    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string]$Repository = 'rustdesk/rustdesk',

    [string]$StateDir,

    [ValidateRange(0, 100)]
    [int]$KeepBackups = 1,

    # Switch defaulting to $true so it can be turned off with -WriteUpdateLog:$false,
    # which (unlike a [bool] parameter) also works with "powershell.exe -File".
    [switch]$WriteUpdateLog = $true,

    [ValidateNotNullOrEmpty()]
    [string]$UpdateLogName = 'update.log',

    [ValidateNotNullOrEmpty()]
    [string]$ManifestName = 'rustdesk.json',

    [switch]$RequireValidSignature,

    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # Invoke-WebRequest is much faster without the progress bar

# Windows PowerShell 5.1 may default to TLS 1.0/1.1 on older systems; GitHub requires TLS 1.2+
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

#region Constants and platform catalog
$UserAgent       = 'rustdesk-client-updater'
$ReplaceRetries  = 10    # attempts when a target file is locked (e.g. being served)
$ReplaceDelaySec = 15    # seconds between attempts
$Ver             = '\d+(?:\.\d+)*'

# Asset: regex on GitHub asset names. File: published name (Windows names are generated).
# WinPrefix: file name prefix for Windows targets (must differ between Windows targets).
$Catalog = [ordered]@{
    'windows-x64'          = @{ Asset = "^rustdesk-$Ver-x86_64\.exe$";        File = $null; WinPrefix = 'rustdesk' }
    'windows-arm64'        = @{ Asset = "^rustdesk-$Ver-aarch64\.exe$";       File = $null; WinPrefix = 'rustdesk-arm64' }
    'macos-arm64'          = @{ Asset = "^rustdesk-$Ver-aarch64\.dmg$";       File = 'rustdesk-macos-arm64.dmg' }
    'macos-x64'            = @{ Asset = "^rustdesk-$Ver-x86_64\.dmg$";        File = 'rustdesk-macos-x64.dmg' }
    'linux-x64-deb'        = @{ Asset = "^rustdesk-$Ver-x86_64\.deb$";        File = 'rustdesk-linux-x64.deb' }
    'linux-arm64-deb'      = @{ Asset = "^rustdesk-$Ver-aarch64\.deb$";       File = 'rustdesk-linux-arm64.deb' }
    'linux-x64-rpm'        = @{ Asset = "^rustdesk-$Ver-\d+\.x86_64\.rpm$";   File = 'rustdesk-linux-x64.rpm' }
    'linux-arm64-rpm'      = @{ Asset = "^rustdesk-$Ver-\d+\.aarch64\.rpm$";  File = 'rustdesk-linux-arm64.rpm' }
    'linux-x64-suse-rpm'   = @{ Asset = "^rustdesk-$Ver-\d+\.x86_64-suse\.rpm$";  File = 'rustdesk-linux-x64-suse.rpm' }
    'linux-arm64-suse-rpm' = @{ Asset = "^rustdesk-$Ver-\d+\.aarch64-suse\.rpm$"; File = 'rustdesk-linux-arm64-suse.rpm' }
    'linux-x64-appimage'   = @{ Asset = "^rustdesk-$Ver-x86_64\.AppImage$";   File = 'rustdesk-linux-x64.AppImage' }
    'linux-arm64-appimage' = @{ Asset = "^rustdesk-$Ver-aarch64\.AppImage$";  File = 'rustdesk-linux-arm64.AppImage' }
}

# Magic bytes per extension (hex). Offset -512 = 512 bytes before end of file (DMG "koly" trailer).
$Magic = @{
    '.exe'      = @{ Offset = 0;    Hex = '4d5a' }
    '.msi'      = @{ Offset = 0;    Hex = 'd0cf11e0a1b11ae1' }
    '.deb'      = @{ Offset = 0;    Hex = '213c617263683e0a' }
    '.rpm'      = @{ Offset = 0;    Hex = 'edabeedb' }
    '.appimage' = @{ Offset = 0;    Hex = '7f454c46' }
    '.dmg'      = @{ Offset = -512; Hex = '6b6f6c79' }
}
#endregion

#region Configuration validation
function Exit-ConfigError {
    param([string]$Message)
    [Console]::Error.WriteLine("Configuration error: $Message")
    exit 2
}

$ServerHost  = $ServerHost.Trim()
$Key         = $Key.Trim()
$RelayServer = $RelayServer.Trim()
$ApiServer   = $ApiServer.Trim().TrimEnd('/')

foreach ($pair in @(@('ServerHost', $ServerHost), @('Key', $Key), @('RelayServer', $RelayServer), @('ApiServer', $ApiServer))) {
    if ($pair[1] -match '[,\s"]') { Exit-ConfigError "$($pair[0]) must not contain commas, spaces or quotes." }
}

# Normalize platforms: accepts arrays and comma-separated strings (needed with -File)
$requested = @($Platforms | ForEach-Object { $_ -split '[,;\s]+' } | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })
foreach ($p in $requested) {
    if (-not $Catalog.Contains($p)) { Exit-ConfigError "Unknown platform '$p'. Valid: $($Catalog.Keys -join ', ')." }
}
$Selected = @($Catalog.Keys | Where-Object { $requested -contains $_ })
if ($Selected.Count -eq 0) { Exit-ConfigError 'No platform selected.' }

$invalidChars = [IO.Path]::GetInvalidFileNameChars()
foreach ($n in @($UpdateLogName, $ManifestName)) {
    if ($n.IndexOfAny($invalidChars) -ge 0) { Exit-ConfigError "Invalid file name '$n'." }
}

if (-not (Test-Path -LiteralPath $TargetDir -PathType Container)) {
    Exit-ConfigError "Target directory not found: $TargetDir"
}
$TargetDir = (Resolve-Path -LiteralPath $TargetDir).ProviderPath

if (-not $StateDir) {
    $StateDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).ProviderPath }
}
try {
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    $StateDir = (Resolve-Path -LiteralPath $StateDir).ProviderPath
} catch {
    Exit-ConfigError "Cannot create state directory '$StateDir': $($_.Exception.Message)"
}
#endregion

#region Server configuration encoding and file names
function Get-EncodedConfig {
    # Same format as RustDesk "Export server config": reversed, URL-safe base64 (no padding)
    # of {"host","relay","api","key"}. Leading JSON whitespace is added when needed so the
    # result contains no "--" and does not start/end with "-", which would break the
    # "--" delimited file-name parser of RustDesk.
    $body = ([ordered]@{ host = $ServerHost; relay = $ConfigRelay; api = $ApiServer; key = $Key } |
             ConvertTo-Json -Compress).Substring(1)
    for ($pad = 0; $pad -le 32; $pad++) {
        $json  = '{' + (' ' * $pad) + $body
        $b64   = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        $chars = $b64.ToCharArray()
        [array]::Reverse($chars)
        $enc = -join $chars
        if (-not $enc.Contains('--') -and -not $enc.StartsWith('-') -and -not $enc.EndsWith('-')) { return $enc }
    }
    throw 'Unable to encode the server configuration.'
}

function Get-PlainConfig {
    # host=<host>,key=<key>[,relay=<relay>][,api=<api>]
    $parts = @("host=$ServerHost", "key=$Key")
    if ($RelayServer) { $parts += "relay=$RelayServer" }
    if ($ApiServer)   { $parts += "api=$ApiServer" }
    return ($parts -join ',')
}

# Relay written in the macOS/Linux configuration: explicit relay, or the ID server host
# (same server RustDesk would use anyway, but visible in the imported settings).
# Windows plain file names keep only an explicit -RelayServer.
$ConfigRelay = if ($RelayServer) { $RelayServer } else { $ServerHost }

$EncodedConfig = Get-EncodedConfig
$PlainConfig   = Get-PlainConfig

# Plain names are readable but every value must be valid in a Windows file name
$plainSafe = ($PlainConfig.IndexOfAny([char[]]'\/:*?"<>|') -lt 0)
$EffectiveStyle = $NameStyle
if ($NameStyle -eq 'Auto') { $EffectiveStyle = if ($plainSafe) { 'Plain' } else { 'Encoded' } }
if ($EffectiveStyle -eq 'Plain' -and -not $plainSafe) {
    Exit-ConfigError "A value contains characters invalid in Windows file names (\ / : * ? `" < > |). Use -NameStyle Encoded or Auto."
}

# Published file name per selected platform
$FileNames = [ordered]@{}
foreach ($p in $Selected) {
    $entry = $Catalog[$p]
    if ($entry.File) {
        $FileNames[$p] = $entry.File
    } elseif ($EffectiveStyle -eq 'Plain') {
        # Trailing comma: keeps the key intact if the browser appends " (1)" to duplicates
        $FileNames[$p] = '{0}-{1},.exe' -f $entry.WinPrefix, $PlainConfig
    } else {
        $FileNames[$p] = '{0}--{1}--.exe' -f $entry.WinPrefix, $EncodedConfig
    }
}
#endregion

#region Derived paths
# Short stable ID of the target directory: lets several targets share one StateDir
$sha = [Security.Cryptography.SHA256]::Create()
try {
    $hashBytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($TargetDir.ToLowerInvariant()))
} finally { $sha.Dispose() }
$InstanceId = -join ($hashBytes[0..5] | ForEach-Object { $_.ToString('x2') })

$LogFile      = Join-Path $StateDir 'rustdesk-client-updater.log'
$StateFile    = Join-Path $StateDir "state-$InstanceId.json"
$BackupRoot   = Join-Path (Join-Path $StateDir 'backup') $InstanceId
$ManifestPath = Join-Path $TargetDir $ManifestName

$script:TmpDir      = $null   # temporary download folder, removed on exit
$script:StagingFile = $null   # copy inside TargetDir pending rename, removed on failure
#endregion

#region Helpers
function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $line = '{0} [{1}] [{2}] {3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $InstanceId, $Message
    try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 } catch { }
    if ($Level -eq 'INFO') { Write-Host $line } else { [Console]::Error.WriteLine($line) }
}

function Write-Utf8File {
    # UTF-8 without BOM (same output on PowerShell 5.1 and 7)
    param([string]$Path, [string]$Content)
    [IO.File]::WriteAllText($Path, $Content, (New-Object Text.UTF8Encoding($false)))
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) } catch { return $null }
}

function Get-FileHexAt {
    # Hex string of $Count bytes at $Offset (negative = from end of file); '' if out of range
    param([string]$Path, [long]$Offset, [int]$Count)
    $fs = [IO.File]::OpenRead($Path)
    try {
        $pos = if ($Offset -lt 0) { $fs.Length + $Offset } else { $Offset }
        if ($pos -lt 0 -or $pos + $Count -gt $fs.Length) { return '' }
        [void]$fs.Seek($pos, [IO.SeekOrigin]::Begin)
        $buf = New-Object byte[] $Count
        $n = $fs.Read($buf, 0, $Count)
        if ($n -ne $Count) { return '' }
        return -join ($buf | ForEach-Object { $_.ToString('x2') })
    } finally { $fs.Dispose() }
}

function Test-FileMagic {
    # True if the file signature matches its extension (unknown extensions pass)
    param([string]$Path)
    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if (-not $Magic.ContainsKey($ext)) { return $true }
    $m = $Magic[$ext]
    return ((Get-FileHexAt -Path $Path -Offset $m.Offset -Count ($m.Hex.Length / 2)) -eq $m.Hex)
}

function Install-File {
    # Stages $Source inside TargetDir, then swaps it in; retries while the target is locked
    param([string]$Source, [string]$Destination)
    $script:StagingFile = Join-Path $TargetDir ('.{0}.partial' -f [IO.Path]::GetFileName($Destination))
    Copy-Item -LiteralPath $Source -Destination $script:StagingFile -Force

    for ($i = 1; $i -le $ReplaceRetries; $i++) {
        try {
            if (Test-Path -LiteralPath $Destination -PathType Leaf) {
                # [NullString]::Value: PowerShell would otherwise pass $null as "" (invalid path)
                [IO.File]::Replace($script:StagingFile, $Destination, [NullString]::Value)   # keeps target ACLs
            } else {
                [IO.File]::Move($script:StagingFile, $Destination)
            }
            $script:StagingFile = $null
            return
        } catch {
            # Retry only on lock/access errors; anything else is fatal immediately
            $inner = if ($_.Exception.InnerException) { $_.Exception.InnerException } else { $_.Exception }
            $retryable = $inner -is [IO.IOException] -or $inner -is [UnauthorizedAccessException]
            if (-not $retryable -or $i -eq $ReplaceRetries) { throw "Cannot replace '$Destination': $($inner.Message)" }
            Write-Log "File busy (attempt $i/$ReplaceRetries): $($inner.Message)" 'WARN'
            Start-Sleep -Seconds $ReplaceDelaySec
        }
    }
}

function Get-ManagedFiles {
    # Plain file names listed in a manifest object
    param($Manifest)
    $names = @()
    if ($Manifest -and $Manifest.PSObject.Properties['files'] -and $Manifest.files) {
        foreach ($prop in $Manifest.files.PSObject.Properties) {
            $f = [string]$prop.Value.file
            if ($f -and $f.IndexOfAny($invalidChars) -lt 0) { $names += $f }
        }
    }
    return $names
}

function Backup-PublishedFiles {
    # Copies the currently published files of a release into BackupRoot\<timestamp>_<version>
    param($OldManifest)
    if ($KeepBackups -le 0) { return }
    $files = @(Get-ManagedFiles $OldManifest | Where-Object { Test-Path -LiteralPath (Join-Path $TargetDir $_) -PathType Leaf })
    if ($files.Count -eq 0) { return }

    $label = if ($OldManifest.PSObject.Properties['version']) { [string]$OldManifest.version } else { 'unknown' }
    $dir = Join-Path $BackupRoot ('{0}_{1}' -f (Get-Date -Format 'yyyyMMddHHmmss'), $label)
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    foreach ($f in $files) { Copy-Item -LiteralPath (Join-Path $TargetDir $f) -Destination (Join-Path $dir $f) -Force }

    # Folder names start with a timestamp, so sorting by name is chronological
    Get-ChildItem -LiteralPath $BackupRoot -Directory |
        Sort-Object Name -Descending |
        Select-Object -Skip $KeepBackups |
        Remove-Item -Recurse -Force
}
#endregion

#region Main logic
function Invoke-Update {
    # --- Latest release ---
    $headers = @{
        'User-Agent'           = $UserAgent
        'Accept'               = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    if ($env:GITHUB_TOKEN) { $headers['Authorization'] = 'Bearer ' + $env:GITHUB_TOKEN }

    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases/latest" -Headers $headers -TimeoutSec 60
    } catch {
        $status = $null
        try { $status = [int]$_.Exception.Response.StatusCode } catch { }
        $detail = if ($status) { " (HTTP $status)" } else { '' }
        $hint   = if ($status -eq 403 -or $status -eq 429) { ' Rate limit? Set GITHUB_TOKEN.' } else { '' }
        throw "GitHub API request failed for $Repository$detail. $($_.Exception.Message)$hint"
    }
    $version = ([string]$release.tag_name).TrimStart('v')
    if (-not $version) { throw 'The latest release has no tag name.' }

    # --- Change detection: version, platforms, file names and server configuration ---
    $fingerprint = '{0}|{1}|{2}' -f $version, (($FileNames.Keys | ForEach-Object { "$_=$($FileNames[$_])" }) -join ';'), $EncodedConfig
    $state       = Read-JsonFile $StateFile
    $oldManifest = Read-JsonFile $ManifestPath
    $allPresent  = (Test-Path -LiteralPath $ManifestPath -PathType Leaf) -and
                   -not ($FileNames.Values | Where-Object { -not (Test-Path -LiteralPath (Join-Path $TargetDir $_) -PathType Leaf) })
    $oldVersion  = if ($state -and $state.PSObject.Properties['version']) { [string]$state.version } else { '' }

    if (-not $Force -and $allPresent -and $state -and $state.PSObject.Properties['fingerprint'] -and $state.fingerprint -eq $fingerprint) {
        Write-Log "Up to date: $version is already published."
        return 0
    }
    $from = if ($oldVersion) { $oldVersion } else { 'unknown' }
    Write-Log "Publishing $from -> $version ($($Selected -join ', '))."

    # --- Download and verify every platform before touching TargetDir ---
    $script:TmpDir = Join-Path ([IO.Path]::GetTempPath()) ('rustdesk-client-updater-' + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $script:TmpDir -Force | Out-Null

    $downloads = @()
    $skipped   = @()
    foreach ($p in $Selected) {
        $rx    = $Catalog[$p].Asset
        $asset = @($release.assets | Where-Object { $_.name -match $rx }) | Select-Object -First 1
        if (-not $asset) {
            Write-Log "Platform $p skipped: no asset matching '$rx' in release $version." 'WARN'
            $skipped += $p
            continue
        }

        # Keep the asset name/extension: magic check and Authenticode depend on it
        $tmp = Join-Path $script:TmpDir ([string]$asset.name)
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmp -UseBasicParsing `
            -Headers @{ 'User-Agent' = $UserAgent } -TimeoutSec 1800

        $size = (Get-Item -LiteralPath $tmp).Length
        if ($size -ne [int64]$asset.size) { throw "$($asset.name): size mismatch (expected $($asset.size), got $size)." }

        $hash = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($asset.PSObject.Properties['digest'] -and ([string]$asset.digest) -match '^sha256:([0-9a-fA-F]{64})$') {
            if ($hash -ne $Matches[1].ToLowerInvariant()) { throw "$($asset.name): SHA-256 mismatch." }
        } else {
            Write-Log "$($asset.name): no SHA-256 digest published; hash check skipped." 'WARN'
        }

        if (-not (Test-FileMagic -Path $tmp)) { throw "$($asset.name): file signature does not match its type." }

        if ([IO.Path]::GetExtension($tmp) -eq '.exe') {
            if (Get-Command -Name Get-AuthenticodeSignature -ErrorAction SilentlyContinue) {
                $sig = Get-AuthenticodeSignature -LiteralPath $tmp
                if ($sig.Status -eq 'Valid') {
                    Write-Log "$($asset.name): valid signature ($($sig.SignerCertificate.Subject))."
                } elseif ($RequireValidSignature) {
                    throw "$($asset.name): signature check failed (status: $($sig.Status))."
                } else {
                    Write-Log "$($asset.name): signature not valid or missing (status: $($sig.Status))." 'WARN'
                }
            } elseif ($RequireValidSignature) {
                throw 'Authenticode verification is not available on this platform.'
            }
        }

        Write-Log "$($asset.name): verified ($size bytes)."
        $downloads += [pscustomobject]@{ Platform = $p; Asset = [string]$asset.name; Temp = $tmp; File = $FileNames[$p]; Size = $size; Sha256 = $hash }
    }
    if ($downloads.Count -eq 0) { throw 'No platform could be downloaded.' }

    # --- Publish ---
    Backup-PublishedFiles -OldManifest $oldManifest
    foreach ($d in $downloads) { Install-File -Source $d.Temp -Destination (Join-Path $TargetDir $d.File) }

    # Remove files published by the previous run that are no longer part of the set
    $newNames = @($downloads | ForEach-Object { $_.File })
    foreach ($old in (Get-ManagedFiles $oldManifest)) {
        $path = Join-Path $TargetDir $old
        if ($newNames -notcontains $old -and (Test-Path -LiteralPath $path -PathType Leaf)) {
            Remove-Item -LiteralPath $path -Force
            Write-Log "Removed obsolete file $old."
        }
    }

    # Manifest for the download page
    $files = [ordered]@{}
    foreach ($d in $downloads) {
        $files[$d.Platform] = [ordered]@{ file = $d.File; asset = $d.Asset; size = $d.Size; sha256 = $d.Sha256 }
    }
    $manifest = [ordered]@{
        version   = $version
        published = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        server    = [ordered]@{ host = $ServerHost; relay = $ConfigRelay; api = $ApiServer; key = $Key }
        config    = $EncodedConfig
        files     = $files
    }
    $tmpManifest = Join-Path $script:TmpDir $ManifestName
    Write-Utf8File -Path $tmpManifest -Content ($manifest | ConvertTo-Json -Depth 6)
    Install-File -Source $tmpManifest -Destination $ManifestPath

    Write-Utf8File -Path $StateFile -Content ([ordered]@{ version = $version; fingerprint = $fingerprint } | ConvertTo-Json)
    Write-Log "Published $version to $TargetDir ($($downloads.Count) files)."

    # --- Public update log (only when something was published) ---
    if ($WriteUpdateLog) {
        $line = '{0} | {1} -> {2} | {3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $from, $version, (($downloads | ForEach-Object { $_.Platform }) -join ', ')
        try {
            Add-Content -LiteralPath (Join-Path $TargetDir $UpdateLogName) -Value $line -Encoding UTF8
        } catch {
            Write-Log "Could not write update log: $($_.Exception.Message)" 'WARN'
        }
    }

    if ($skipped.Count -gt 0) { return 3 }
    return 0
}
#endregion

#region Entry point
$exitCode  = 0
$mutex     = $null
$ownsMutex = $false

try {
    # One run at a time per target directory
    $mutex = New-Object System.Threading.Mutex($false, "Global\RustDeskClientUpdater-$InstanceId")
    try {
        $ownsMutex = $mutex.WaitOne(0)
    } catch {
        # A previous run died while holding the mutex: we own it now
        if ($_.Exception -is [Threading.AbandonedMutexException] -or
            $_.Exception.InnerException -is [Threading.AbandonedMutexException]) { $ownsMutex = $true } else { throw }
    }

    if ($ownsMutex) {
        # Last pipeline value is the return code (guards against stray output)
        $exitCode = [int](Invoke-Update | Select-Object -Last 1)
    } else {
        Write-Log 'Another run for this target is in progress; skipping.'
    }
} catch {
    Write-Log $_.Exception.Message 'ERROR'
    $exitCode = 1
} finally {
    if ($script:StagingFile -and (Test-Path -LiteralPath $script:StagingFile)) {
        Remove-Item -LiteralPath $script:StagingFile -Force -ErrorAction SilentlyContinue
    }
    if ($script:TmpDir -and (Test-Path -LiteralPath $script:TmpDir)) {
        Remove-Item -LiteralPath $script:TmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($mutex) {
        if ($ownsMutex) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

exit $exitCode
#endregion
