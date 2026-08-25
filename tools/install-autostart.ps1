#requires -Version 5.1
<#
.SYNOPSIS
    Install / remove chlorophyll autostart and (optionally) one-click control
    shortcuts. No admin required - everything lives under the current user's
    Startup folder, Desktop, and per-user Task Scheduler.
.DESCRIPTION
    Default        : a hidden Startup-folder shortcut that launches the .ps1.
    -Exe           : autostart the prebuilt build\chlorophyll.exe instead.
    -ScheduledTask : register an at-logon task in the current user's context.
    -Shortcuts     : drop Pause 1h / Resume / Off-for-today shortcuts on the Desktop.
    -Uninstall     : remove everything this script installed.
.EXAMPLE
    tools\install-autostart.ps1
    tools\install-autostart.ps1 -Exe -Shortcuts
    tools\install-autostart.ps1 -ScheduledTask
    tools\install-autostart.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [switch]$Exe,
    [switch]$ScheduledTask,
    [switch]$Shortcuts,
    [switch]$Uninstall,
    [ValidateSet('Debug', 'Info', 'Warn', 'Off')][string]$LogLevel = 'Info'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot   = Split-Path $PSScriptRoot -Parent
$ScriptPath = Join-Path $RepoRoot 'src\ps\Chlorophyll.ps1'
$ExePath    = Join-Path $RepoRoot 'build\chlorophyll.exe'
$Startup    = [Environment]::GetFolderPath('Startup')
$Desktop    = [Environment]::GetFolderPath('Desktop')
$PsExe      = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

$StartupLnk = Join-Path $Startup 'chlorophyll.lnk'
$TaskName   = 'chlorophyll'
$DesktopLnks = @(
    (Join-Path $Desktop 'chlorophyll - Pause 1h.lnk'),
    (Join-Path $Desktop 'chlorophyll - Resume.lnk'),
    (Join-Path $Desktop 'chlorophyll - Off for today.lnk')
)

$wsh = New-Object -ComObject WScript.Shell

function New-Lnk($path, $target, $arguments, $desc, $iconStyle = 7) {
    $sc = $wsh.CreateShortcut($path)
    $sc.TargetPath       = $target
    $sc.Arguments        = $arguments
    $sc.WorkingDirectory = $RepoRoot
    $sc.WindowStyle      = $iconStyle
    $sc.Description      = $desc
    $sc.Save()
}

# Build the (target, args) pair for a given Chlorophyll verb, honoring -Exe.
function Get-Invocation($verb, $verbArg) {
    if ($Exe) {
        $a = @($verb.ToLower()); if ($verbArg) { $a += $verbArg }
        return @{ Target = $ExePath; Args = ($a -join ' ').Trim() }
    }
    $a = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptPath`" -$verb"
    if ($verbArg) { $a += " $verbArg" }
    if ($verb -eq 'Start') { $a += " -LogLevel $LogLevel" }
    return @{ Target = $PsExe; Args = $a }
}

if ($Uninstall) {
    foreach ($p in @($StartupLnk) + $DesktopLnks) {
        if (Test-Path $p) { Remove-Item $p -Force; Write-Host "Removed $p" }
    }
    try {
        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            Write-Host "Removed scheduled task '$TaskName'"
        }
    } catch { }
    # Also remove the encoded-launcher shortcut if present.
    $encoded = Join-Path $Startup 'chlorophyll (encoded).lnk'
    if (Test-Path $encoded) { Remove-Item $encoded -Force; Write-Host "Removed $encoded" }
    Write-Host 'Uninstall complete.'
    return
}

# --- validation ------------------------------------------------------------
if ($Exe -and -not (Test-Path $ExePath)) {
    throw "build\chlorophyll.exe not found. Run tools\build-exe.ps1 first, or omit -Exe."
}
if (-not $Exe -and -not (Test-Path $ScriptPath)) {
    throw "Chlorophyll.ps1 not found at $ScriptPath"
}

# --- autostart -------------------------------------------------------------
$start = Get-Invocation 'Start'
if ($ScheduledTask) {
    $action  = New-ScheduledTaskAction -Execute $start.Target -Argument $start.Args -WorkingDirectory $RepoRoot
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $set     = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $set -Force | Out-Null
    Write-Host "Registered at-logon scheduled task '$TaskName' (current user)."
}
else {
    New-Lnk $StartupLnk $start.Target $start.Args 'chlorophyll presence keeper'
    Write-Host "Created Startup shortcut: $StartupLnk"
}

# --- one-click control shortcuts ------------------------------------------
if ($Shortcuts) {
    $pause  = Get-Invocation 'PauseFor' '60'
    $resume = Get-Invocation 'Resume'
    $off    = Get-Invocation 'Off'
    New-Lnk $DesktopLnks[0] $pause.Target  $pause.Args  'Pause chlorophyll for 1 hour'
    New-Lnk $DesktopLnks[1] $resume.Target $resume.Args 'Resume chlorophyll'
    New-Lnk $DesktopLnks[2] $off.Target    $off.Args    'Turn chlorophyll off for the rest of today'
    Write-Host 'Created Desktop control shortcuts: Pause 1h / Resume / Off for today.'
}

Write-Host ''
Write-Host 'Done. To remove everything:  tools\install-autostart.ps1 -Uninstall'
