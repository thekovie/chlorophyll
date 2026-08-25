# Pester 3.4-compatible. Run: Invoke-Pester tests\
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here '..\src\ps\modules\Config.psm1')   -Force -DisableNameChecking
Import-Module (Join-Path $here '..\src\ps\modules\Schedule.psm1') -Force -DisableNameChecking

# A known configuration. 2026-08-26 is a Wednesday; 2026-08-29 a Saturday.
$cfg = Resolve-ChlorophyllConfig ([ordered]@{
    WorkDays='Mon,Tue,Wed,Thu,Fri'; WorkStart='08:00'; WorkEnd='17:30'
    LunchStart='12:00'; LunchMinutes='45'; LunchJitterMinutes='0'
})
$noLunch = Resolve-ChlorophyllConfig ([ordered]@{ LunchStart=''; WorkStart='08:00'; WorkEnd='17:30' })

Describe 'Get-DayAbbrev' {
    It 'maps DayOfWeek to three-letter form' {
        (Get-DayAbbrev (Get-Date '2026-08-26')) | Should Be 'Wed'
        (Get-DayAbbrev (Get-Date '2026-08-29')) | Should Be 'Sat'
    }
}

Describe 'Test-InWorkWindow' {
    It 'is active mid-morning on a work day' {
        (Test-InWorkWindow -Now (Get-Date '2026-08-26 10:00') -Config $cfg) | Should Be $true
    }
    It 'is inactive on a weekend' {
        (Test-InWorkWindow -Now (Get-Date '2026-08-29 10:00') -Config $cfg) | Should Be $false
    }
    It 'is inactive before start and at/after end (half-open window)' {
        (Test-InWorkWindow -Now (Get-Date '2026-08-26 07:59') -Config $cfg) | Should Be $false
        (Test-InWorkWindow -Now (Get-Date '2026-08-26 08:00') -Config $cfg) | Should Be $true
        (Test-InWorkWindow -Now (Get-Date '2026-08-26 17:30') -Config $cfg) | Should Be $false
        (Test-InWorkWindow -Now (Get-Date '2026-08-26 17:29') -Config $cfg) | Should Be $true
    }
    It 'is inactive inside the lunch gap and active just outside it' {
        (Test-InWorkWindow -Now (Get-Date '2026-08-26 12:20') -Config $cfg)     | Should Be $false
        (Test-InWorkWindow -Now (Get-Date '2026-08-26 12:44') -Config $cfg)     | Should Be $false
        (Test-InWorkWindow -Now (Get-Date '2026-08-26 12:45') -Config $cfg)     | Should Be $true
        (Test-InWorkWindow -Now (Get-Date '2026-08-26 11:59') -Config $cfg)     | Should Be $true
    }
    It 'ignores the lunch gap when disabled' {
        (Test-InWorkWindow -Now (Get-Date '2026-08-26 12:20') -Config $noLunch) | Should Be $true
    }
}

Describe 'Get-LunchGap' {
    It 'returns null when disabled' {
        (Get-LunchGap -Date (Get-Date '2026-08-26') -Config $noLunch) | Should Be $null
    }
    It 'spans LunchMinutes from LunchStart with zero jitter' {
        $g = Get-LunchGap -Date (Get-Date '2026-08-26') -Config $cfg
        $g.Start.ToString('HH:mm') | Should Be '12:00'
        $g.End.ToString('HH:mm')   | Should Be '12:45'
    }
}

Describe 'Get-DailyJitterOffset' {
    It 'is zero when jitter is zero' {
        (Get-DailyJitterOffset -Date (Get-Date '2026-08-26') -Jitter 0) | Should Be 0
    }
    It 'stays within +/- jitter and is stable for a given date' {
        $a = Get-DailyJitterOffset -Date (Get-Date '2026-08-26') -Jitter 15
        $b = Get-DailyJitterOffset -Date (Get-Date '2026-08-26') -Jitter 15
        $a | Should Be $b
        ($a -ge -15 -and $a -le 15) | Should Be $true
    }
}

Describe 'Get-NextInterval' {
    It 'returns a value within [Min,Max]' {
        $r = [System.Random]::new(1)
        1..50 | ForEach-Object {
            $v = Get-NextInterval -MinSec 30 -MaxSec 90 -Random $r
            ($v -ge 30 -and $v -le 90) | Should Be $true
        }
    }
    It 'returns Min when Max <= Min' {
        (Get-NextInterval -MinSec 40 -MaxSec 40) | Should Be 40
    }
}

Describe 'Get-NextWorkStart' {
    It 'rolls Saturday forward to Monday 08:00' {
        $n = Get-NextWorkStart -Now (Get-Date '2026-08-29 10:00') -Config $cfg
        $n.ToString('ddd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture) | Should Be 'Mon 08:00'
    }
    It 'from a weekday afternoon points to the next morning' {
        $n = Get-NextWorkStart -Now (Get-Date '2026-08-26 15:00') -Config $cfg
        $n.ToString('ddd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture) | Should Be 'Thu 08:00'
    }
}
