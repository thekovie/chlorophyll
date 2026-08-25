#requires -Version 5.1
<#
.SYNOPSIS
    Put a 'chlorophyll' command on your PATH so you can run it from any terminal
    (e.g. `chlorophyll -status`) without cd-ing to the repo or naming the .ps1.
.DESCRIPTION
    Writes a tiny launcher, %LOCALAPPDATA%\chlorophyll\bin\chlorophyll.cmd, that
    forwards all arguments to Chlorophyll.ps1 (or to build\chlorophyll.exe with
    -Exe), then adds that bin folder to your *user* PATH. No admin required.

    Open a NEW terminal after installing (PATH is read at shell start). Then:
        chlorophyll -status
        chlorophyll -pausefor 60
        chlorophyll -help
.EXAMPLE
    tools\install-command.ps1
.EXAMPLE
    tools\install-command.ps1 -Exe        # forward to the prebuilt exe instead
.EXAMPLE
    tools\install-command.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [switch]$Exe,
    [switch]$Uninstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot   = Split-Path $PSScriptRoot -Parent
$ScriptPath = Join-Path $RepoRoot 'src\ps\Chlorophyll.ps1'
$ExePath    = Join-Path $RepoRoot 'build\chlorophyll.exe'
$BinDir     = Join-Path $env:LOCALAPPDATA 'chlorophyll\bin'
$CmdPath    = Join-Path $BinDir 'chlorophyll.cmd'

function Get-UserPath { [Environment]::GetEnvironmentVariable('Path', 'User') }

function Remove-FromUserPath($dir) {
    $cur = Get-UserPath
    if (-not $cur) { return }
    $parts = $cur.Split(';') | Where-Object { $_ -and ($_.TrimEnd('\') -ne $dir.TrimEnd('\')) }
    [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
}

if ($Uninstall) {
    if (Test-Path $CmdPath) { Remove-Item $CmdPath -Force; Write-Host "Removed $CmdPath" }
    Remove-FromUserPath $BinDir
    Write-Host "Removed $BinDir from your user PATH."
    Write-Host 'Open a new terminal for the change to take effect.'
    return
}

# --- validation ------------------------------------------------------------
if ($Exe -and -not (Test-Path $ExePath)) {
    throw "build\chlorophyll.exe not found. Run tools\build-exe.ps1 first, or omit -Exe."
}
if (-not $Exe -and -not (Test-Path $ScriptPath)) {
    throw "Chlorophyll.ps1 not found at $ScriptPath"
}

# --- write the launcher ----------------------------------------------------
if (-not (Test-Path $BinDir)) { $null = New-Item -ItemType Directory -Path $BinDir -Force }

if ($Exe) {
    # Forward args straight to the exe. `chlorophyll status`, `chlorophyll pause`, etc.
    $cmd = @(
        '@echo off',
        "`"$ExePath`" %*"
    )
} else {
    # Forward args to the script. Works with the dashed verbs: chlorophyll -status.
    $cmd = @(
        '@echo off',
        "powershell -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" %*"
    )
}
Set-Content -LiteralPath $CmdPath -Value $cmd -Encoding ASCII

# --- add bin to user PATH (idempotent) -------------------------------------
$userPath = Get-UserPath
$already  = $userPath -and ($userPath.Split(';') | Where-Object { $_.TrimEnd('\') -eq $BinDir.TrimEnd('\') })
if (-not $already) {
    $newPath = if ([string]::IsNullOrEmpty($userPath)) { $BinDir } else { "$userPath;$BinDir" }
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    Write-Host "Added to your user PATH: $BinDir"
} else {
    Write-Host "Already on your user PATH: $BinDir"
}

Write-Host ''
Write-Host "Installed launcher: $CmdPath"
Write-Host 'Open a NEW terminal, then try:'
if ($Exe) {
    Write-Host '  chlorophyll status'
    Write-Host '  chlorophyll pausefor 60'
} else {
    Write-Host '  chlorophyll -status'
    Write-Host '  chlorophyll -pausefor 60'
    Write-Host '  chlorophyll -help'
}
Write-Host ''
Write-Host 'To remove:  tools\install-command.ps1 -Uninstall'
