# Pester 3.4-compatible (the in-box Windows version). Run: Invoke-Pester tests\
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here '..\src\ps\modules\Config.psm1') -Force -DisableNameChecking

Describe 'ConvertTo-TimeOfDay' {
    It 'parses HH:mm to minutes' {
        (ConvertTo-TimeOfDay '08:00') | Should Be 480
        (ConvertTo-TimeOfDay '17:30') | Should Be 1050
        (ConvertTo-TimeOfDay '0:05')  | Should Be 5
    }
    It 'rejects malformed times' {
        { ConvertTo-TimeOfDay '8am' }   | Should Throw
        { ConvertTo-TimeOfDay '25:00' } | Should Throw
        { ConvertTo-TimeOfDay '10:75' } | Should Throw
    }
}

Describe 'ConvertTo-Bool' {
    It 'accepts truthy and falsy spellings' {
        (ConvertTo-Bool 'true')  | Should Be $true
        (ConvertTo-Bool 'ON')    | Should Be $true
        (ConvertTo-Bool '0')     | Should Be $false
        (ConvertTo-Bool 'no')    | Should Be $false
    }
    It 'rejects nonsense' { { ConvertTo-Bool 'maybe' } | Should Throw }
}

Describe 'ConvertFrom-IniText' {
    It 'ignores comments and blanks' {
        $h = ConvertFrom-IniText "# c`n; c2`n`nWorkStart = 09:00"
        $h['WorkStart'] | Should Be '09:00'
        $h.Keys.Count   | Should Be 1
    }
    It 'throws on a line with no equals' {
        { ConvertFrom-IniText 'this is not valid' } | Should Throw
    }
}

Describe 'Import/Resolve defaults' {
    It 'returns full defaults for an empty config' {
        $c = Resolve-ChlorophyllConfig ([ordered]@{})
        $c.WorkStart      | Should Be '08:00'
        $c.NudgeMethod    | Should Be 'F15'
        $c.MinIntervalSec | Should Be 30
        $c.PreventLock    | Should Be $true
        ($c.WorkDays -join ',') | Should Be 'Mon,Tue,Wed,Thu,Fri'
    }
    It 'missing file yields defaults, not an error' {
        $c = Import-ChlorophyllConfig -Path 'Z:\does\not\exist.conf'
        $c.WorkEnd | Should Be '17:30'
    }
}

Describe 'Overrides and coercion' {
    It 'coerces ints and bools and normalizes days' {
        $raw = [ordered]@{ MinIntervalSec='45'; PreventDisplayOff='false'; WorkDays='mon, wed , fri' }
        $c = Resolve-ChlorophyllConfig $raw
        $c.MinIntervalSec    | Should Be 45
        $c.PreventDisplayOff | Should Be $false
        ($c.WorkDays -join ',') | Should Be 'Mon,Wed,Fri'
    }
    It 'blank LunchStart is allowed (gap disabled)' {
        $c = Resolve-ChlorophyllConfig ([ordered]@{ LunchStart='' })
        $c.LunchStart | Should Be ''
    }
}

Describe 'Validation invariants' {
    It 'rejects Max < Min interval' {
        { Resolve-ChlorophyllConfig ([ordered]@{ MinIntervalSec='90'; MaxIntervalSec='30' }) } | Should Throw
    }
    It 'rejects WorkEnd <= WorkStart' {
        { Resolve-ChlorophyllConfig ([ordered]@{ WorkStart='17:00'; WorkEnd='09:00' }) } | Should Throw
    }
    It 'rejects an unknown day' {
        { Resolve-ChlorophyllConfig ([ordered]@{ WorkDays='Mon,Funday' }) } | Should Throw
    }
    It 'rejects an unknown NudgeMethod' {
        { Resolve-ChlorophyllConfig ([ordered]@{ NudgeMethod='Wiggle' }) } | Should Throw
    }
    It 'rejects too-small MinIntervalSec' {
        { Resolve-ChlorophyllConfig ([ordered]@{ MinIntervalSec='1' }) } | Should Throw
    }
}

Describe 'Unknown keys' {
    It 'warns but does not fail on an unknown key' {
        $c = Resolve-ChlorophyllConfig ([ordered]@{ Nonsense='x'; WorkStart='09:00' }) -WarningAction SilentlyContinue
        $c.WorkStart | Should Be '09:00'
    }
}
