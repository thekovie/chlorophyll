#requires -Version 5.1
<#
.SYNOPSIS
    Read-only preflight: tells you which chlorophyll execution tier this machine
    actually allows, and smoke-tests the idle-reset. Changes nothing.
.DESCRIPTION
    Run this FIRST on the target laptop. It inspects execution policy, language
    mode, AppLocker/WDAC posture, and the presence of the inbox csc.exe, then
    names the highest tier that will run here. See README.md for the tier list.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

function Line($label, $value) { Write-Host ("  {0,-24}: {1}" -f $label, $value) }

Write-Host ''
Write-Host 'chlorophyll doctor - read-only environment check'
Write-Host '================================================'

# --- language mode (kills tiers 1 & 2) -------------------------------------
$langMode = $ExecutionContext.SessionState.LanguageMode
Line 'Language mode' $langMode

# --- execution policy (AllSigned kills tier 1 script files) ----------------
$effPolicy = Get-ExecutionPolicy
$policies  = Get-ExecutionPolicy -List | ForEach-Object { "$($_.Scope)=$($_.ExecutionPolicy)" }
Line 'Effective ExecPolicy' $effPolicy
Line 'ExecPolicy scopes' ($policies -join '  ')

# --- inbox csc.exe (needed for tier 4; irrelevant to tiers 1-3) ------------
$csc = @(
    "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
    "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
Line 'Inbox csc.exe' ($(if ($csc) { $csc } else { 'NOT FOUND' }))

# --- AppLocker / WDAC hints (best-effort, non-authoritative) ---------------
$appLocker = 'unknown'
try {
    $svc = Get-Service -Name AppIDSvc -ErrorAction SilentlyContinue
    if ($svc) { $appLocker = "AppIDSvc=$($svc.Status)" }
} catch { }
Line 'AppLocker service' $appLocker

$wdac = 'unknown'
try {
    $ci = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard -ErrorAction SilentlyContinue
    if ($ci) {
        if ($ci.CodeIntegrityPolicyEnforcementStatus -ge 2) { $wdac = 'ENFORCED' } else { $wdac = 'audit/off' }
    }
} catch { }
Line 'WDAC code integrity' $wdac

# --- Reflection.Emit smoke test (tier 1 depends on it) ---------------------
$emitOk = $false
try {
    $an = [System.Reflection.AssemblyName]::new('chlorophyll_doctor')
    $ab = [System.AppDomain]::CurrentDomain.DefineDynamicAssembly($an, [System.Reflection.Emit.AssemblyBuilderAccess]::Run)
    $null = $ab.DefineDynamicModule('m')
    $emitOk = $true
} catch { }
Line 'Reflection.Emit works' $emitOk

# --- idle read smoke test (via the real module) ----------------------------
$idleOk = $false
$idleVal = 'n/a'
try {
    Import-Module (Join-Path $PSScriptRoot '..\src\ps\modules\Nudge.psm1') -Force -DisableNameChecking
    $idleVal = Get-IdleSeconds
    $idleOk = $true
} catch { $idleVal = "error: $($_.Exception.Message)" }
Line 'GetLastInputInfo read' "$idleOk (idle=${idleVal}s)"

# --- Teams present? (informational only) -----------------------------------
$teams = Get-Process -Name 'ms-teams', 'Teams' -ErrorAction SilentlyContinue
Line 'Teams running' ($(if ($teams) { 'yes' } else { 'no (not required to test)' }))

# --- verdict ---------------------------------------------------------------
Write-Host ''
Write-Host 'Verdict'
Write-Host '-------'
$constrained = ($langMode -eq 'ConstrainedLanguage')
$allSigned   = ($effPolicy -eq 'AllSigned')

if (-not $constrained -and -not $allSigned -and $emitOk) {
    Write-Host '  Tier 1 (PowerShell script) should run. This is the simplest path:'
    Write-Host '    powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File src\ps\Chlorophyll.ps1 -Start'
}
elseif (-not $constrained -and $emitOk) {
    Write-Host '  ExecutionPolicy blocks plain script files, but Tier 2 (encoded launcher) should run:'
    Write-Host '    tools\make-encoded-launcher.ps1   (then use the Startup shortcut it creates)'
}
elseif ($constrained) {
    Write-Host '  Constrained Language Mode is active - Tiers 1 & 2 are out. Use the exe:'
    Write-Host '    Tier 3: build tools\build-exe.ps1 on an UNRESTRICTED machine, copy build\chlorophyll.exe over.'
    if ($csc) { Write-Host '    Tier 4: or run tools\build-exe.ps1 here (inbox csc.exe was found).' }
    Write-Host '  If AppLocker/WDAC also blocks unsigned exes, no unsigned user code will run here by design.'
}
else {
    Write-Host '  Mixed signals - try Tier 1 first; if it is blocked, fall to the exe (Tier 3).'
}
Write-Host ''
Write-Host '  (Nothing was changed. This was a read-only check.)'
Write-Host ''
