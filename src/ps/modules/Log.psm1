<#
.SYNOPSIS
    Small leveled logger with size-based rotation.
.DESCRIPTION
    Writes to %LOCALAPPDATA%\chlorophyll\logs\chlorophyll.log. Levels:
    Debug < Info < Warn < Off. Anything at or above the configured threshold is
    written; Off silences everything. Line format:
        2026-08-25T14:03:11 | Info | message text
#>

Set-StrictMode -Version Latest

$script:LevelRank = @{ 'Debug' = 0; 'Info' = 1; 'Warn' = 2; 'Off' = 99 }
$script:Threshold = 1          # default Info
$script:LogPath   = $null
$script:MaxBytes  = 512KB
$script:MaxRolls  = 3

function Get-ChlorophyllDataDir {
    # %LOCALAPPDATA%\chlorophyll, created on demand. Everything we persist lives here.
    $base = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($base)) { $base = [System.IO.Path]::GetTempPath() }
    $dir = Join-Path $base 'chlorophyll'
    if (-not (Test-Path -LiteralPath $dir)) {
        $null = New-Item -ItemType Directory -Path $dir -Force
    }
    return $dir
}

function Initialize-Log {
    [CmdletBinding()]
    param([ValidateSet('Debug', 'Info', 'Warn', 'Off')][string]$Level = 'Info')
    $script:Threshold = $script:LevelRank[$Level]
    $logDir = Join-Path (Get-ChlorophyllDataDir) 'logs'
    if (-not (Test-Path -LiteralPath $logDir)) {
        $null = New-Item -ItemType Directory -Path $logDir -Force
    }
    $script:LogPath = Join-Path $logDir 'chlorophyll.log'
}

function Invoke-LogRotation {
    if ($null -eq $script:LogPath) { return }
    if (-not (Test-Path -LiteralPath $script:LogPath)) { return }
    if ((Get-Item -LiteralPath $script:LogPath).Length -lt $script:MaxBytes) { return }

    # chlorophyll.log -> .1 -> .2 ... dropping the oldest.
    for ($i = $script:MaxRolls; $i -ge 1; $i--) {
        $src = if ($i -eq 1) { $script:LogPath } else { "$($script:LogPath).$($i-1)" }
        $dst = "$($script:LogPath).$i"
        if (Test-Path -LiteralPath $src) {
            Move-Item -LiteralPath $src -Destination $dst -Force -ErrorAction SilentlyContinue
        }
    }
}

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Message,
        [Parameter(Position = 1)][ValidateSet('Debug', 'Info', 'Warn')][string]$Level = 'Info'
    )
    if ($script:LevelRank[$Level] -lt $script:Threshold) { return }
    if ($null -eq $script:LogPath) { Initialize-Log }

    $stamp = (Get-Date).ToString('s')          # ISO-8601 local, e.g. 2026-08-25T14:03:11
    $line  = "$stamp | $Level | $Message"
    try {
        Invoke-LogRotation
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch {
        # Never let logging take the loop down.
    }
    Write-Verbose $line
}

function Get-LogPath { return $script:LogPath }

Export-ModuleMember -Function `
    Get-ChlorophyllDataDir, Initialize-Log, Write-Log, Get-LogPath
