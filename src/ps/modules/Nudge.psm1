<#
.SYNOPSIS
    The only interop surface: idle-timer reset, idle query, and lock/sleep hold.
.DESCRIPTION
    Builds its P/Invoke stubs with Reflection.Emit (AssemblyBuilder ->
    DefinePInvokeMethod) instead of Add-Type, so it needs no compiler at run
    time. On Windows PowerShell 5.1, Add-Type shells out to csc.exe; an EDR that
    blocks csc.exe (a common LOLBin rule) would otherwise take out both the script
    path and the compile-on-target path at once. Reflection.Emit keeps this tier
    independent of the compiler.

    Signatures are deliberately all-primitive / IntPtr so no custom struct types
    have to be emitted:
      keybd_event / mouse_event  - synthesize the no-op input
      GetLastInputInfo(IntPtr)   - fed a raw 8-byte buffer, not a struct type
      GetTickCount               - for the idle delta
      SetThreadExecutionState    - the lock/sleep hold
      GetConsoleWindow/ShowWindow- hide the console for the .ps1 path

    Note: keybd_event/mouse_event are the legacy input APIs. They still fully
    work on Windows 10/11 and update the last-input time exactly like SendInput,
    while being trivial to bind without emitting an INPUT union. Injected input
    is flagged LLKHF_INJECTED either way; this tool does not hide that.
#>

Set-StrictMode -Version Latest

# Virtual-key / flag constants.
$script:VK_F15                = 0x7E
$script:VK_SCROLL             = 0x91
$script:KEYEVENTF_KEYUP       = 0x0002
$script:MOUSEEVENTF_MOVE      = 0x0001
# 0x80000000 overflows Int32, so build it as a wider literal before the cast.
$script:ES_CONTINUOUS         = [uint32]2147483648
$script:ES_SYSTEM_REQUIRED    = [uint32]1
$script:ES_DISPLAY_REQUIRED   = [uint32]2
$script:SW_HIDE               = 0

$script:Native = $null   # cached emitted type

function Initialize-NativeInterop {
    <#
    .SYNOPSIS
        Emit (once) and return the Chlorophyll.Native type carrying the P/Invoke
        stubs. Throws a clear error if the runtime forbids Reflection.Emit
        (e.g. full Constrained Language Mode) so the caller can fall to another tier.
    #>
    [CmdletBinding()]
    param()
    if ($null -ne $script:Native) { return $script:Native }

    try {
        $asmName = [System.Reflection.AssemblyName]::new('ChlorophyllNative')
        $asm = [System.AppDomain]::CurrentDomain.DefineDynamicAssembly(
            $asmName, [System.Reflection.Emit.AssemblyBuilderAccess]::Run)
        $mod = $asm.DefineDynamicModule('ChlorophyllNativeModule')
        $tb  = $mod.DefineType('Chlorophyll.Native',
            ([System.Reflection.TypeAttributes]::Public -bor [System.Reflection.TypeAttributes]::Class))

        $winapi   = [System.Runtime.InteropServices.CallingConvention]::Winapi
        $charAuto = [System.Runtime.InteropServices.CharSet]::Auto
        $attrs    = [System.Reflection.MethodAttributes]::Public `
                -bor [System.Reflection.MethodAttributes]::Static `
                -bor [System.Reflection.MethodAttributes]::PinvokeImpl
        $stdCall  = [System.Reflection.CallingConventions]::Standard

        $define = {
            param($name, $dll, $ret, [Type[]]$params)
            $mb = $tb.DefinePInvokeMethod($name, $dll, $attrs, $stdCall, $ret, $params, $winapi, $charAuto)
            $mb.SetImplementationFlags(
                $mb.GetMethodImplementationFlags() -bor [System.Reflection.MethodImplAttributes]::PreserveSig)
        }

        & $define 'keybd_event'             'user32.dll'   ([void])     @([byte], [byte], [uint32], [System.UIntPtr])
        & $define 'mouse_event'             'user32.dll'   ([void])     @([uint32], [uint32], [uint32], [uint32], [System.UIntPtr])
        & $define 'GetLastInputInfo'        'user32.dll'   ([bool])     @([System.IntPtr])
        & $define 'GetTickCount'            'kernel32.dll' ([uint32])   @()
        & $define 'SetThreadExecutionState' 'kernel32.dll' ([uint32])   @([uint32])
        & $define 'GetConsoleWindow'        'kernel32.dll' ([System.IntPtr]) @()
        & $define 'ShowWindow'              'user32.dll'   ([bool])     @([System.IntPtr], [int])

        $script:Native = $tb.CreateType()
        return $script:Native
    }
    catch {
        throw "chlorophyll: cannot build native interop (Reflection.Emit blocked?): $($_.Exception.Message)"
    }
}

function Get-IdleSeconds {
    <#
    .SYNOPSIS
        Seconds since the last real (or injected) user input, via GetLastInputInfo.
    #>
    [CmdletBinding()]
    param()
    $native = Initialize-NativeInterop
    $buf = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(8)
    try {
        # LASTINPUTINFO { uint cbSize=8; uint dwTime; }
        [System.Runtime.InteropServices.Marshal]::WriteInt32($buf, 0, 8)
        if (-not $native::GetLastInputInfo($buf)) { return 0 }
        $dwTime = [uint32][System.Runtime.InteropServices.Marshal]::ReadInt32($buf, 4)
        $now    = [uint32]$native::GetTickCount()
        # Unsigned subtraction handles the 49.7-day tick wraparound correctly.
        $deltaMs = [uint32]($now - $dwTime)
        return [int]([math]::Floor($deltaMs / 1000))
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($buf)
    }
}

function Invoke-Nudge {
    <#
    .SYNOPSIS
        Reset the idle timer with a genuine no-op, using the configured method.
    #>
    [CmdletBinding()]
    param([ValidateSet('F15', 'MouseJiggle', 'ScrollLock')][string]$Method = 'F15')
    $native = Initialize-NativeInterop
    $none   = [System.UIntPtr]::Zero

    switch ($Method) {
        'F15' {
            $native::keybd_event([byte]$script:VK_F15, [byte]0, [uint32]0, $none)
            $native::keybd_event([byte]$script:VK_F15, [byte]0, [uint32]$script:KEYEVENTF_KEYUP, $none)
        }
        'ScrollLock' {
            # Toggle twice so the actual Scroll Lock state ends where it started.
            foreach ($i in 1..2) {
                $native::keybd_event([byte]$script:VK_SCROLL, [byte]0, [uint32]0, $none)
                $native::keybd_event([byte]$script:VK_SCROLL, [byte]0, [uint32]$script:KEYEVENTF_KEYUP, $none)
            }
        }
        'MouseJiggle' {
            # Relative move of (0,0): registers as input, moves the cursor nowhere.
            $native::mouse_event([uint32]$script:MOUSEEVENTF_MOVE, [uint32]0, [uint32]0, [uint32]0, $none)
        }
    }
}

function Set-ExecutionStateHold {
    <#
    .SYNOPSIS
        Assert a continuous system (and optionally display) requirement so the
        machine won't sleep / turn the display off / idle-lock while we hold it.
    #>
    [CmdletBinding()]
    param([bool]$PreventLock = $true, [bool]$PreventDisplayOff = $true)
    $native = Initialize-NativeInterop
    $flags  = $script:ES_CONTINUOUS
    if ($PreventLock)       { $flags = $flags -bor $script:ES_SYSTEM_REQUIRED }
    if ($PreventDisplayOff) { $flags = $flags -bor $script:ES_DISPLAY_REQUIRED }
    $null = $native::SetThreadExecutionState([uint32]$flags)
}

function Clear-ExecutionStateHold {
    <#
    .SYNOPSIS
        Drop the hold: back to plain ES_CONTINUOUS so normal power policy resumes.
    #>
    [CmdletBinding()]
    param()
    $native = Initialize-NativeInterop
    $null = $native::SetThreadExecutionState([uint32]$script:ES_CONTINUOUS)
}

function Hide-ConsoleWindow {
    <#
    .SYNOPSIS
        Hide this process's console window (best-effort; the .exe tiers need none).
    #>
    [CmdletBinding()]
    param()
    try {
        $native = Initialize-NativeInterop
        $h = $native::GetConsoleWindow()
        if ($h -ne [System.IntPtr]::Zero) { $null = $native::ShowWindow($h, $script:SW_HIDE) }
    } catch { }
}

Export-ModuleMember -Function `
    Initialize-NativeInterop, Get-IdleSeconds, Invoke-Nudge,
    Set-ExecutionStateHold, Clear-ExecutionStateHold, Hide-ConsoleWindow
