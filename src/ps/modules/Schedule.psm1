<#
.SYNOPSIS
    Pure scheduling logic: is now inside the work window, where's the lunch gap,
    how long to sleep before the next tick, when does the next work day start.
.DESCRIPTION
    No interop, no disk, no clock reads except what you pass in. Everything takes
    an explicit [datetime]$Now so it is fully unit-testable. This is where all the
    "should I be active right now" decisions live.
#>

Set-StrictMode -Version Latest

$script:DayAbbrev = @{
    'Sunday' = 'Sun'; 'Monday' = 'Mon'; 'Tuesday' = 'Tue'; 'Wednesday' = 'Wed'
    'Thursday' = 'Thu'; 'Friday' = 'Fri'; 'Saturday' = 'Sat'
}

function Get-DayAbbrev {
    param([Parameter(Mandatory)][datetime]$When)
    return $script:DayAbbrev[$When.DayOfWeek.ToString()]
}

function Get-TimeOfDayMinutes {
    # Minutes since midnight for a DateTime.
    param([Parameter(Mandatory)][datetime]$When)
    return ($When.Hour * 60 + $When.Minute)
}

function Get-DailyJitterOffset {
    <#
    .SYNOPSIS
        Deterministic per-day jitter in [-Jitter, +Jitter] minutes.
    .DESCRIPTION
        Seeded by the calendar date so the lunch gap sits at one stable spot all
        day (no flapping tick-to-tick) but moves day to day. No RNG state needed.
    #>
    param(
        [Parameter(Mandatory)][datetime]$Date,
        [Parameter(Mandatory)][int]$Jitter
    )
    if ($Jitter -le 0) { return 0 }
    # DayNumber gives a stable integer per date; spread it and fold into range.
    $seed  = [int]($Date.Date.Ticks -shr 32) -bxor $Date.DayOfYear -bxor $Date.Year
    $span  = (2 * $Jitter) + 1
    $mod   = [math]::Abs($seed) % $span
    return ($mod - $Jitter)
}

function Get-LunchGap {
    <#
    .SYNOPSIS
        Returns @{ Start=<datetime>; End=<datetime> } for the given day's lunch
        gap, or $null when the gap is disabled (blank LunchStart or 0 minutes).
    #>
    param(
        [Parameter(Mandatory)][datetime]$Date,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config
    )
    if ([string]::IsNullOrWhiteSpace([string]$Config.LunchStart)) { return $null }
    if ([int]$Config.LunchMinutes -le 0) { return $null }

    $m = [regex]::Match([string]$Config.LunchStart, '^(\d{1,2}):(\d{2})$')
    if (-not $m.Success) { return $null }
    $baseMin = ([int]$m.Groups[1].Value) * 60 + [int]$m.Groups[2].Value
    $offset  = Get-DailyJitterOffset -Date $Date -Jitter ([int]$Config.LunchJitterMinutes)

    $start = $Date.Date.AddMinutes($baseMin + $offset)
    $end   = $start.AddMinutes([int]$Config.LunchMinutes)
    return @{ Start = $start; End = $end }
}

function Test-InWorkWindow {
    <#
    .SYNOPSIS
        $true when $Now falls on a configured work day, inside [WorkStart,WorkEnd),
        and outside the lunch gap. This is the master "be active" gate.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][datetime]$Now,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config
    )

    $today = Get-DayAbbrev -When $Now
    if ($today -notin $Config.WorkDays) { return $false }

    $mins  = Get-TimeOfDayMinutes -When $Now
    $start = ([int]($Config.WorkStart -split ':')[0]) * 60 + [int]($Config.WorkStart -split ':')[1]
    $end   = ([int]($Config.WorkEnd   -split ':')[0]) * 60 + [int]($Config.WorkEnd   -split ':')[1]
    if ($mins -lt $start -or $mins -ge $end) { return $false }

    $gap = Get-LunchGap -Date $Now -Config $Config
    if ($null -ne $gap -and $Now -ge $gap.Start -and $Now -lt $gap.End) { return $false }

    return $true
}

function Get-NextInterval {
    <#
    .SYNOPSIS
        A jittered sleep length in seconds, uniformly in [Min, Max].
    .PARAMETER Random
        Optional System.Random for deterministic tests; a fresh one otherwise.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$MinSec,
        [Parameter(Mandatory)][int]$MaxSec,
        [System.Random]$Random
    )
    if ($MaxSec -le $MinSec) { return $MinSec }
    if (-not $Random) { $Random = [System.Random]::new() }
    # Next's upper bound is exclusive; +1 makes MaxSec reachable.
    return $Random.Next($MinSec, $MaxSec + 1)
}

function Get-NextWorkStart {
    <#
    .SYNOPSIS
        The next DateTime at which a configured work day begins, strictly after
        $Now. Used by -Off to schedule tomorrow's auto-resume.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][datetime]$Now,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config
    )
    $startMin = ([int]($Config.WorkStart -split ':')[0]) * 60 + [int]($Config.WorkStart -split ':')[1]
    for ($i = 0; $i -le 14; $i++) {
        $day      = $Now.Date.AddDays($i)
        $candidate = $day.AddMinutes($startMin)
        if ($candidate -le $Now) { continue }
        if ((Get-DayAbbrev -When $day) -in $Config.WorkDays) { return $candidate }
    }
    # Should never happen given WorkDays is non-empty; fall back to tomorrow.
    return $Now.Date.AddDays(1).AddMinutes($startMin)
}

Export-ModuleMember -Function `
    Get-DayAbbrev, Get-TimeOfDayMinutes, Get-DailyJitterOffset, Get-LunchGap,
    Test-InWorkWindow, Get-NextInterval, Get-NextWorkStart
