# Pester 3.4-compatible. Run: Invoke-Pester tests\
#
# These are smoke tests, not deterministic assertions: the interop's real effect
# (resetting the system idle timer) can't be isolated in a unit test on a live
# desktop. We verify the shim emits, the calls succeed, and types are sane. The
# deterministic idle-reset proof is the manual step in README / the plan.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here '..\src\ps\modules\Nudge.psm1') -Force -DisableNameChecking

Describe 'Initialize-NativeInterop' {
    It 'emits a type exposing the expected P/Invoke methods' {
        $t = Initialize-NativeInterop
        $t | Should Not BeNullOrEmpty
        ($t.GetMethod('keybd_event'))             | Should Not BeNullOrEmpty
        ($t.GetMethod('GetLastInputInfo'))        | Should Not BeNullOrEmpty
        ($t.GetMethod('SetThreadExecutionState')) | Should Not BeNullOrEmpty
    }
    It 'is idempotent (returns the same cached type)' {
        (Initialize-NativeInterop) | Should Be (Initialize-NativeInterop)
    }
}

Describe 'Get-IdleSeconds' {
    It 'returns a non-negative integer' {
        $s = Get-IdleSeconds
        ($s -is [int]) | Should Be $true
        ($s -ge 0)     | Should Be $true
    }
}

Describe 'Invoke-Nudge' {
    It 'does not throw for any supported method' {
        { Invoke-Nudge -Method F15 }         | Should Not Throw
        { Invoke-Nudge -Method ScrollLock }  | Should Not Throw
        { Invoke-Nudge -Method MouseJiggle } | Should Not Throw
    }
    It 'a nudge drives idle down to a small value' {
        Start-Sleep -Milliseconds 1200
        Invoke-Nudge -Method F15
        Start-Sleep -Milliseconds 150
        (Get-IdleSeconds) | Should BeLessThan 2
    }
}

Describe 'Execution-state hold' {
    It 'asserts and clears without throwing' {
        { Set-ExecutionStateHold -PreventLock $true -PreventDisplayOff $true } | Should Not Throw
        { Clear-ExecutionStateHold } | Should Not Throw
    }
}
