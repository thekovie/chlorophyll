<#
.SYNOPSIS
    Loads and validates chlorophyll's INI-style configuration.
.DESCRIPTION
    Pure logic, no interop. Parses `key = value` lines (# and ; comments),
    layers them over built-in defaults, coerces types, and validates. Designed
    to run under Constrained Language Mode and Windows PowerShell 5.1 with no
    dependency on ConvertFrom-Json / System.Text.Json.
#>

Set-StrictMode -Version Latest

# Every knob, with its default. Get-DefaultConfig is the single source of truth
# for what a fully-populated config object looks like.
function Get-DefaultConfig {
    [CmdletBinding()]
    param()
    [ordered]@{
        WorkDays              = @('Mon', 'Tue', 'Wed', 'Thu', 'Fri')
        WorkStart             = '08:00'
        WorkEnd               = '17:30'
        LunchStart            = '12:00'
        LunchMinutes          = 45
        LunchJitterMinutes    = 15
        NudgeMethod           = 'F15'
        MinIntervalSec        = 30
        MaxIntervalSec        = 90
        NudgeAfterIdleSeconds = 45
        PreventLock           = $true
        PreventDisplayOff     = $true
        LogLevel              = 'Info'
    }
}

$script:ValidDays        = @('Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun')
$script:ValidNudge       = @('F15', 'MouseJiggle', 'ScrollLock')
$script:ValidLogLevels   = @('Debug', 'Info', 'Warn', 'Off')
$script:KnownKeys        = (Get-DefaultConfig).Keys

function ConvertTo-Bool {
    param([Parameter(Mandatory)][string]$Value)
    switch ($Value.Trim().ToLowerInvariant()) {
        { $_ -in @('true', '1', 'yes', 'on') }  { return $true }
        { $_ -in @('false', '0', 'no', 'off') } { return $false }
        default { throw "expected a boolean (true/false), got '$Value'" }
    }
}

function ConvertTo-TimeOfDay {
    # Returns minutes-since-midnight for an "HH:mm" string; throws on malformed.
    param([Parameter(Mandatory)][string]$Value)
    $m = [regex]::Match($Value.Trim(), '^(\d{1,2}):(\d{2})$')
    if (-not $m.Success) { throw "expected time as HH:mm, got '$Value'" }
    $h  = [int]$m.Groups[1].Value
    $mi = [int]$m.Groups[2].Value
    if ($h -gt 23 -or $mi -gt 59) { throw "time out of range: '$Value'" }
    return ($h * 60 + $mi)
}

function ConvertFrom-IniText {
    # Splits raw INI text into an ordered hashtable of string values.
    # Public-ish helper so tests can feed text without touching disk.
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $result = [ordered]@{}
    $lineNo = 0
    foreach ($raw in ($Text -split "`r?`n")) {
        $lineNo++
        $line = $raw.Trim()
        if ($line.Length -eq 0)            { continue }
        if ($line.StartsWith('#'))         { continue }
        if ($line.StartsWith(';'))         { continue }
        $eq = $line.IndexOf('=')
        if ($eq -lt 1) { throw "config line ${lineNo}: expected 'key = value', got '$raw'" }
        $key = $line.Substring(0, $eq).Trim()
        $val = $line.Substring($eq + 1).Trim()
        $result[$key] = $val
    }
    return $result
}

function Resolve-ChlorophyllConfig {
    <#
    .SYNOPSIS
        Merge raw INI key/values over defaults and return a validated config.
    .PARAMETER Raw
        Ordered hashtable of string values (from ConvertFrom-IniText).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Raw)

    $cfg = Get-DefaultConfig

    # Warn (don't fail) on unknown keys so a typo is visible but not fatal.
    $unknown = @($Raw.Keys | Where-Object { $_ -notin $script:KnownKeys })
    if ($unknown.Count -gt 0) {
        Write-Warning ("chlorophyll config: ignoring unknown key(s): {0}" -f ($unknown -join ', '))
    }

    foreach ($key in $Raw.Keys) {
        if ($key -notin $script:KnownKeys) { continue }
        $v = [string]$Raw[$key]
        try {
            switch ($key) {
                'WorkDays' {
                    $days = @($v -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                    $norm = foreach ($d in $days) {
                        $match = $script:ValidDays | Where-Object { $_ -ieq $d }
                        if (-not $match) { throw "unknown day '$d' (use Mon..Sun)" }
                        $match
                    }
                    $cfg[$key] = @($norm)
                }
                'WorkStart'             { $null = ConvertTo-TimeOfDay $v; $cfg[$key] = $v }
                'WorkEnd'               { $null = ConvertTo-TimeOfDay $v; $cfg[$key] = $v }
                'LunchStart' {
                    if ([string]::IsNullOrWhiteSpace($v)) { $cfg[$key] = '' }
                    else { $null = ConvertTo-TimeOfDay $v; $cfg[$key] = $v }
                }
                'LunchMinutes'          { $cfg[$key] = [int]$v }
                'LunchJitterMinutes'    { $cfg[$key] = [int]$v }
                'MinIntervalSec'        { $cfg[$key] = [int]$v }
                'MaxIntervalSec'        { $cfg[$key] = [int]$v }
                'NudgeAfterIdleSeconds' { $cfg[$key] = [int]$v }
                'NudgeMethod' {
                    $match = $script:ValidNudge | Where-Object { $_ -ieq $v.Trim() }
                    if (-not $match) { throw "unknown NudgeMethod '$v' (F15|MouseJiggle|ScrollLock)" }
                    $cfg[$key] = $match
                }
                'PreventLock'           { $cfg[$key] = ConvertTo-Bool $v }
                'PreventDisplayOff'     { $cfg[$key] = ConvertTo-Bool $v }
                'LogLevel' {
                    $match = $script:ValidLogLevels | Where-Object { $_ -ieq $v.Trim() }
                    if (-not $match) { throw "unknown LogLevel '$v' (Debug|Info|Warn|Off)" }
                    $cfg[$key] = $match
                }
            }
        }
        catch {
            throw "chlorophyll config: key '$key': $($_.Exception.Message)"
        }
    }

    Assert-ConfigInvariants -Config $cfg
    return $cfg
}

function Assert-ConfigInvariants {
    # Cross-field checks that a single key can't express on its own.
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)

    if ($Config.MinIntervalSec -lt 5) {
        throw "MinIntervalSec must be >= 5 (got $($Config.MinIntervalSec))"
    }
    if ($Config.MaxIntervalSec -lt $Config.MinIntervalSec) {
        throw "MaxIntervalSec ($($Config.MaxIntervalSec)) must be >= MinIntervalSec ($($Config.MinIntervalSec))"
    }
    if ($Config.NudgeAfterIdleSeconds -lt 0) {
        throw "NudgeAfterIdleSeconds must be >= 0 (got $($Config.NudgeAfterIdleSeconds))"
    }
    if ($Config.LunchMinutes -lt 0)       { throw "LunchMinutes must be >= 0" }
    if ($Config.LunchJitterMinutes -lt 0) { throw "LunchJitterMinutes must be >= 0" }
    if ((ConvertTo-TimeOfDay $Config.WorkEnd) -le (ConvertTo-TimeOfDay $Config.WorkStart)) {
        throw "WorkEnd ($($Config.WorkEnd)) must be after WorkStart ($($Config.WorkStart))"
    }
    if ($Config.WorkDays.Count -eq 0) {
        throw "WorkDays must list at least one day"
    }
}

function Import-ChlorophyllConfig {
    <#
    .SYNOPSIS
        Read a config file from disk and return a validated config object.
        A missing file yields the full set of defaults (no error).
    #>
    [CmdletBinding()]
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return (Resolve-ChlorophyllConfig -Raw ([ordered]@{}))
    }
    $text = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    $raw  = ConvertFrom-IniText -Text $text
    return (Resolve-ChlorophyllConfig -Raw $raw)
}

Export-ModuleMember -Function `
    Get-DefaultConfig, ConvertFrom-IniText, Resolve-ChlorophyllConfig,
    Assert-ConfigInvariants, Import-ChlorophyllConfig, ConvertTo-TimeOfDay, ConvertTo-Bool
