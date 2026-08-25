#requires -Version 5.1
<#
.SYNOPSIS
    Tier 2 launcher. Base64-encodes the "-Start" invocation of Chlorophyll.ps1
    into a Startup-folder shortcut that calls powershell -EncodedCommand.
.DESCRIPTION
    ExecutionPolicy governs script *files*, not -Command / -EncodedCommand, so
    this path runs even under an AllSigned machine policy where the plain .ps1
    would be refused. (Still blocked by Constrained Language Mode - use the exe
    for that; run tools\doctor.ps1 if unsure.)

    Encoding here is purely to survive ExecutionPolicy and to avoid quoting pain
    in the shortcut target - it is not obfuscation and hides nothing.
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [ValidateSet('Debug', 'Info', 'Warn', 'Off')][string]$LogLevel = 'Info'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot   = Split-Path $PSScriptRoot -Parent
$ScriptPath = Join-Path $RepoRoot 'src\ps\Chlorophyll.ps1'
$Startup    = [Environment]::GetFolderPath('Startup')
$LnkPath    = Join-Path $Startup 'chlorophyll (encoded).lnk'

if ($Uninstall) {
    if (Test-Path $LnkPath) { Remove-Item $LnkPath -Force; Write-Host "Removed $LnkPath" }
    else { Write-Host 'Nothing to remove.' }
    return
}

if (-not (Test-Path $ScriptPath)) { throw "Chlorophyll.ps1 not found at $ScriptPath" }

# The inner command the encoded launcher will run.
$inner = "& '$ScriptPath' -Start -LogLevel $LogLevel"
$bytes = [System.Text.Encoding]::Unicode.GetBytes($inner)
$enc   = [Convert]::ToBase64String($bytes)

$psExe  = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$args   = "-NoProfile -WindowStyle Hidden -EncodedCommand $enc"

$wsh = New-Object -ComObject WScript.Shell
$sc  = $wsh.CreateShortcut($LnkPath)
$sc.TargetPath       = $psExe
$sc.Arguments        = $args
$sc.WorkingDirectory = $RepoRoot
$sc.WindowStyle      = 7           # minimized
$sc.Description      = 'chlorophyll presence keeper (encoded launcher)'
$sc.Save()

Write-Host "Created Startup shortcut: $LnkPath"
Write-Host 'It will start chlorophyll hidden at next logon.'
Write-Host "To start it now without logging off:  Start-Process '$LnkPath'"
Write-Host "To remove:  tools\make-encoded-launcher.ps1 -Uninstall"
