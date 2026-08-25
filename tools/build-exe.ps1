#requires -Version 5.1
<#
.SYNOPSIS
    Compile src\cs\Program.cs into build\chlorophyll.exe using the csc.exe that
    ships inside Windows (.NET Framework 4.x). No SDK, no admin, no download.
.DESCRIPTION
    Tier 3: run this on an unrestricted machine and copy the single .exe to the
    locked-down laptop. Tier 4: run it on the laptop itself. Built /target:winexe
    so the process has no console window.
#>
[CmdletBinding()]
param(
    [string]$OutDir = (Join-Path (Split-Path $PSScriptRoot -Parent) 'build')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$src = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\cs\Program.cs'
if (-not (Test-Path $src)) { throw "Source not found: $src" }

$csc = @(
    "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
    "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $csc) {
    throw "Inbox csc.exe not found. This machine's .NET Framework may be unusually stripped; use the Tier 3 prebuilt exe instead."
}

if (-not (Test-Path $OutDir)) { $null = New-Item -ItemType Directory -Path $OutDir -Force }
$out = Join-Path $OutDir 'chlorophyll.exe'

Write-Host "Compiler : $csc"
Write-Host "Source   : $src"
Write-Host "Output   : $out"

& $csc -nologo -optimize+ -target:winexe "-out:$out" $src
if ($LASTEXITCODE -ne 0) { throw "csc failed with exit code $LASTEXITCODE" }

Write-Host ''
Write-Host "Built OK: $out ($([math]::Round((Get-Item $out).Length/1KB,1)) KB)"
Write-Host 'Run it headless with:  build\chlorophyll.exe'
Write-Host 'Smoke test with:       build\chlorophyll.exe once'
