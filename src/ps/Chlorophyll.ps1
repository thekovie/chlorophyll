#requires -Version 5.1
<#
.SYNOPSIS
    chlorophyll - keep Microsoft Teams presence Available during work hours by
    resetting the Windows idle timer and holding off lock/sleep.

.DESCRIPTION
    Headless presence keeper. Works at the OS layer only: it never touches the
    Teams process, its config, or its auth. See README.md for the honest limits.

.EXAMPLE
    Chlorophyll.ps1 -Start            # run the loop (use -WindowStyle Hidden to launch headless)
    Chlorophyll.ps1 -Once             # one nudge and exit (smoke test)
    Chlorophyll.ps1 -Status           # what's it doing right now
    Chlorophyll.ps1 -Pause            # stop nudging + release lock hold, stay running
    Chlorophyll.ps1 -PauseFor 60      # pause 60 min then auto-resume
    Chlorophyll.ps1 -Resume           # go active now (still respects work hours)
    Chlorophyll.ps1 -Toggle           # flip paused/active
    Chlorophyll.ps1 -Off              # done for today; auto-resume tomorrow at WorkStart
    Chlorophyll.ps1 -Stop             # exit the running loop
#>
[CmdletBinding(DefaultParameterSetName = 'Start')]
param(
    [Parameter(ParameterSetName = 'Start')]    [switch]$Start,
    [Parameter(ParameterSetName = 'Once')]     [switch]$Once,
    [Parameter(ParameterSetName = 'Status')]   [switch]$Status,
    [Parameter(ParameterSetName = 'Stop')]     [switch]$Stop,
    [Parameter(ParameterSetName = 'Pause')]    [switch]$Pause,
    [Parameter(ParameterSetName = 'Resume')]   [switch]$Resume,
    [Parameter(ParameterSetName = 'PauseFor')] [int]$PauseFor,
    [Parameter(ParameterSetName = 'Toggle')]   [switch]$Toggle,
    [Parameter(ParameterSetName = 'Off')]      [switch]$Off,

    [string]$ConfigPath,
    [ValidateSet('Debug', 'Info', 'Warn', 'Off')][string]$LogLevel
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- module import ----------------------------------------------------------
$ModuleDir = Join-Path $PSScriptRoot 'modules'
foreach ($m in 'Config', 'Schedule', 'Nudge', 'Log') {
    Import-Module (Join-Path $ModuleDir "$m.psm1") -Force -DisableNameChecking
}

# --- names / paths ----------------------------------------------------------
# Local\ (per-session) rather than Global\ so no admin rights are needed.
$script:WakeEventName = 'Local\chlorophyll_wake'
$script:MutexName     = 'Local\chlorophyll_singleton'

$DataDir      = Get-ChlorophyllDataDir
$CommandFile  = Join-Path $DataDir 'command'
$StatusFile   = Join-Path $DataDir 'status'

# Resolve the config path: explicit param, else repo-root chlorophyll.conf.
if (-not $ConfigPath) {
    $ConfigPath = Join-Path (Split-Path $PSScriptRoot -Parent | Split-Path -Parent) 'chlorophyll.conf'
}

# ---------------------------------------------------------------------------
# tiny key=value status file helpers (JSON-free so CLM can't choke on them)
# ---------------------------------------------------------------------------
function Write-KvFile {
    param([string]$Path, [System.Collections.IDictionary]$Data)
    $sb = [System.Text.StringBuilder]::new()
    foreach ($k in $Data.Keys) { [void]$sb.AppendLine("$k=$($Data[$k])") }
    Set-Content -LiteralPath $Path -Value $sb.ToString() -Encoding UTF8 -ErrorAction SilentlyContinue
}
function Read-KvFile {
    param([string]$Path)
    $h = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $h }
    foreach ($line in (Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)) {
        $eq = $line.IndexOf('=')
        if ($eq -gt 0) { $h[$line.Substring(0, $eq)] = $line.Substring($eq + 1) }
    }
    return $h
}

function Open-WakeEvent {
    try { return [System.Threading.EventWaitHandle]::new(
            $false, [System.Threading.EventResetMode]::AutoReset, $script:WakeEventName) }
    catch { return $null }
}
function Send-Command {
    # Drop a verb for the running loop and wake it immediately.
    param([string]$Verb)
    Set-Content -LiteralPath $CommandFile -Value $Verb -Encoding UTF8
    $evt = Open-WakeEvent
    if ($evt) { [void]$evt.Set(); $evt.Dispose() }
}

# ---------------------------------------------------------------------------
# control verbs (run as a separate short-lived process)
# ---------------------------------------------------------------------------
function Test-LoopAlive {
    $s = Read-KvFile $StatusFile
    if (-not $s.ContainsKey('Pid')) { return $false }
    $p = Get-Process -Id ([int]$s['Pid']) -ErrorAction SilentlyContinue
    return [bool]$p
}

function Invoke-ControlVerb {
    param([string]$Verb, [string]$Arg)
    if (-not (Test-LoopAlive)) {
        Write-Warning "chlorophyll doesn't appear to be running. Start it with -Start first."
    }
    switch ($Verb) {
        'Pause'    { Send-Command 'Pause';            Write-Host 'Paused. (nudging + lock hold released)' }
        'Resume'   { Send-Command 'Resume';           Write-Host 'Resumed.' }
        'Toggle'   { Send-Command 'Toggle';           Write-Host 'Toggled.' }
        'Off'      { Send-Command 'Off';              Write-Host 'Off for the rest of today; will auto-resume tomorrow.' }
        'PauseFor' { Send-Command "PauseFor:$Arg";    Write-Host "Paused for $Arg minute(s); will auto-resume." }
        'Stop'     { Send-Command 'Stop';             Write-Host 'Stop requested.' }
    }
}

function Show-Status {
    $s = Read-KvFile $StatusFile
    if ($s.Count -eq 0 -or -not (Test-LoopAlive)) {
        Write-Host 'chlorophyll: not running.'
        return
    }
    Write-Host 'chlorophyll status'
    Write-Host '------------------'
    Write-Host ("  State        : {0}" -f ($s['Mode']))
    if ($s['ResumeAt']) { Write-Host ("  Auto-resume  : {0} ({1})" -f $s['ResumeAt'], $s['Reason']) }
    Write-Host ("  In work hours: {0}" -f $s['InWindow'])
    Write-Host ("  Idle (sec)   : {0}" -f $s['IdleSeconds'])
    Write-Host ("  Last nudge   : {0}" -f ($(if ($s['LastNudge']) { $s['LastNudge'] } else { 'none yet' })))
    Write-Host ("  Next wake    : {0}" -f $s['NextWake'])
    Write-Host ("  PID          : {0}" -f $s['Pid'])
    Write-Host ("  Updated      : {0}" -f $s['UpdatedAt'])
}

# ---------------------------------------------------------------------------
# the loop (run under -Start)
# ---------------------------------------------------------------------------
function Start-Loop {
    param([hashtable]$Config)

    $createdNew = $false
    $mutex = [System.Threading.Mutex]::new($true, $script:MutexName, [ref]$createdNew)
    if (-not $createdNew) {
        Write-Warning 'chlorophyll is already running (single-instance lock held). Exiting.'
        return
    }

    $wake = Open-WakeEvent
    $rng  = [System.Random]::new()

    $mode      = 'Active'        # Active | Paused
    $resumeAt  = $null           # [datetime] or $null
    $reason    = ''
    $lastNudge = $null
    $holdOn    = $false

    Write-Log "chlorophyll started (pid $PID). Config: work $($Config.WorkStart)-$($Config.WorkEnd) on $($Config.WorkDays -join ',')." 'Info'

    try {
        while ($true) {
            # 1. consume any pending control verb
            if (Test-Path -LiteralPath $CommandFile) {
                $verb = (Get-Content -LiteralPath $CommandFile -Raw -ErrorAction SilentlyContinue).Trim()
                Remove-Item -LiteralPath $CommandFile -Force -ErrorAction SilentlyContinue
                switch -Regex ($verb) {
                    '^Stop$'   { Write-Log 'Stop received; exiting.' 'Info'; return }
                    '^Pause$'  { $mode = 'Paused'; $resumeAt = $null; $reason = 'manual'; Write-Log 'Paused (manual).' 'Info' }
                    '^Resume$' { $mode = 'Active'; $resumeAt = $null; $reason = '';       Write-Log 'Resumed.' 'Info' }
                    '^Toggle$' {
                        if ($mode -eq 'Active') { $mode = 'Paused'; $resumeAt = $null; $reason = 'manual'; Write-Log 'Toggled -> Paused.' 'Info' }
                        else                    { $mode = 'Active'; $resumeAt = $null; $reason = '';       Write-Log 'Toggled -> Active.' 'Info' }
                    }
                    '^Off$' {
                        $mode = 'Paused'; $resumeAt = Get-NextWorkStart -Now (Get-Date) -Config $Config; $reason = 'offday'
                        Write-Log "Off for today; auto-resume at $($resumeAt.ToString('s'))." 'Info'
                    }
                    '^PauseFor:(\d+)$' {
                        $mins = [int]$Matches[1]
                        $mode = 'Paused'; $resumeAt = (Get-Date).AddMinutes($mins); $reason = 'timed'
                        Write-Log "Paused for $mins min; auto-resume at $($resumeAt.ToString('s'))." 'Info'
                    }
                    default { Write-Log "Ignoring unknown command '$verb'." 'Warn' }
                }
            }

            $now = Get-Date

            # 2. auto-resume if a timed/offday pause has elapsed
            if ($mode -eq 'Paused' -and $null -ne $resumeAt -and $now -ge $resumeAt) {
                $mode = 'Active'; $resumeAt = $null; $reason = ''
                Write-Log 'Auto-resumed.' 'Info'
            }

            $inWindow = Test-InWorkWindow -Now $now -Config $Config
            $active   = ($mode -eq 'Active') -and $inWindow

            # 3. act
            $idle = 0
            if ($active) {
                if (-not $holdOn -and ($Config.PreventLock -or $Config.PreventDisplayOff)) {
                    Set-ExecutionStateHold -PreventLock $Config.PreventLock -PreventDisplayOff $Config.PreventDisplayOff
                    $holdOn = $true
                    Write-Log 'Lock/sleep hold asserted.' 'Debug'
                }
                $idle = Get-IdleSeconds
                if ($idle -ge $Config.NudgeAfterIdleSeconds) {
                    Invoke-Nudge -Method $Config.NudgeMethod
                    $lastNudge = Get-Date
                    Write-Log "Nudge sent ($($Config.NudgeMethod)); idle was ${idle}s." 'Debug'
                } else {
                    Write-Log "Skip nudge; only ${idle}s idle (< $($Config.NudgeAfterIdleSeconds))." 'Debug'
                }
            } else {
                if ($holdOn) {
                    Clear-ExecutionStateHold
                    $holdOn = $false
                    Write-Log 'Lock/sleep hold released (inactive).' 'Debug'
                }
            }

            # 4. decide next wake and publish status
            $intervalSec = if ($active) {
                Get-NextInterval -MinSec $Config.MinIntervalSec -MaxSec $Config.MaxIntervalSec -Random $rng
            } else {
                # Idle cheaply when not active, but stay responsive to commands.
                [math]::Min(60, [math]::Max($Config.MaxIntervalSec, 60))
            }
            $nextWake = (Get-Date).AddSeconds($intervalSec)

            Write-KvFile -Path $StatusFile -Data ([ordered]@{
                Pid         = $PID
                Mode        = $mode
                Reason      = $reason
                ResumeAt    = $(if ($resumeAt) { $resumeAt.ToString('s') } else { '' })
                InWindow    = $inWindow
                IdleSeconds = $idle
                LastNudge   = $(if ($lastNudge) { $lastNudge.ToString('s') } else { '' })
                NextWake    = $nextWake.ToString('s')
                UpdatedAt   = (Get-Date).ToString('s')
            })

            # 5. sleep, but wake instantly if a command arrives
            if ($wake) { [void]$wake.WaitOne([int]($intervalSec * 1000)) }
            else       { Start-Sleep -Seconds $intervalSec }
        }
    }
    finally {
        if ($holdOn) { Clear-ExecutionStateHold }
        Remove-Item -LiteralPath $StatusFile -Force -ErrorAction SilentlyContinue
        if ($wake) { $wake.Dispose() }
        $mutex.ReleaseMutex(); $mutex.Dispose()
        Write-Log 'chlorophyll stopped.' 'Info'
    }
}

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------

# Control/status verbs don't need config or logging init.
switch ($PSCmdlet.ParameterSetName) {
    'Stop'     { Invoke-ControlVerb 'Stop';                 return }
    'Pause'    { Invoke-ControlVerb 'Pause';                return }
    'Resume'   { Invoke-ControlVerb 'Resume';               return }
    'Toggle'   { Invoke-ControlVerb 'Toggle';               return }
    'Off'      { Invoke-ControlVerb 'Off';                  return }
    'PauseFor' { Invoke-ControlVerb 'PauseFor' "$PauseFor"; return }
    'Status'   { Show-Status;                               return }
}

# Start / Once need config + logging.
$config = Import-ChlorophyllConfig -Path $ConfigPath
$effectiveLevel = if ($LogLevel) { $LogLevel } else { $config.LogLevel }
Initialize-Log -Level $effectiveLevel

if ($Once) {
    Write-Log 'Single-shot (-Once): nudging now.' 'Info'
    $before = Get-IdleSeconds
    Invoke-Nudge -Method $config.NudgeMethod
    Start-Sleep -Milliseconds 200
    $after = Get-IdleSeconds
    Write-Host ("Nudge sent ($($config.NudgeMethod)). Idle before={0}s, after={1}s. Log: {2}" -f `
        $before, $after, (Get-LogPath))
    return
}

# default / -Start
Hide-ConsoleWindow
Start-Loop -Config $config
