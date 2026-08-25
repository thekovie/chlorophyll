# chlorophyll

> Keeps you green. A headless background helper that stops Microsoft Teams from
> flipping your presence to **Away** during work hours — by telling *Windows* a
> human is at the keyboard, and letting Teams draw its own conclusion.

chlorophyll never touches the Teams process, its config, its auth tokens, or the
Graph presence API. Teams decides you're Away from two OS signals: the last input
event (`GetLastInputInfo`) and whether the session is locked. chlorophyll resets
the idle timer with a harmless no-op keystroke and (optionally) holds off the
lock/sleep timers. That's the whole trick.

## What it actually does

- Injects a **`F15` keystroke** on a jittered 30–90s cadence. F13–F24 exist in the
  scancode space but sit on no physical keyboard and are mapped by no app, so the
  press is a genuine no-op. (`MouseJiggle` and `ScrollLock` are alternatives.)
- **Only nudges when you're genuinely idle** (default: 45s since real input), so it
  never fights your own typing.
- **Holds off lock and display-off** via `SetThreadExecutionState`, because Teams
  goes Away the instant the workstation locks no matter what input you inject.
- **Runs only during your configured work window** (days + hours, with a randomized
  lunch gap). Outside the window it asserts nothing at all.

## Honest limits — read these

- **Injected input is flagged.** Windows tags synthetic input with `LLKHF_INJECTED`.
  Endpoint/EDR monitoring *can* tell it apart from real typing. chlorophyll does not
  hide this and will not try to.
- **A lock defeats presence.** If a policy locks your screen, Teams goes Away
  regardless of keystrokes — which is why lock prevention exists here. If your
  machine hard-blocks lock prevention, presence-keeping alone may not hold.
- **Keeping the screen on is a physical-security tradeoff.** `PreventDisplayOff`
  leaves your display readable to anyone walking by.
- **It won't override a status you set.** Do Not Disturb / Be Right Back stay put.
  It does not fake "In a meeting" or any calendar state.
- **This is an acceptable-use question at your workplace, not a technical one.**
  On a managed device this may violate policy. That call is yours to make knowingly.

## Requirements

Windows 10/11. Nothing to install — no admin, no Python, no downloads. The
PowerShell path uses only in-box Windows PowerShell; the optional `.exe` compiles
with the `csc.exe` that already ships inside Windows (.NET Framework 4.x).

## Quick start

```powershell
# 1. See what your locked-down machine actually allows (read-only, safe):
powershell -ExecutionPolicy Bypass -File tools\doctor.ps1

# 2. Make your config:
Copy-Item chlorophyll.conf.example chlorophyll.conf   # then edit the hours

# 3. Try a single nudge and watch the log:
powershell -ExecutionPolicy Bypass -File src\ps\Chlorophyll.ps1 -Once -LogLevel Debug

# 4. Run it (hidden, headless):
powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File src\ps\Chlorophyll.ps1 -Start
```

## Controlling it mid-day

```powershell
Chlorophyll.ps1 -Status          # running / paused, next wake, seconds idle, resume time
Chlorophyll.ps1 -Pause           # stop nudging + release lock hold; stays running
Chlorophyll.ps1 -PauseFor 60     # pause 60 min, then auto-resume ("back by 3")
Chlorophyll.ps1 -Resume          # go active now (still respects work hours)
Chlorophyll.ps1 -Toggle          # flip paused/active (bind to a hotkey)
Chlorophyll.ps1 -Off             # done for today; auto-resumes tomorrow at WorkStart
Chlorophyll.ps1 -Stop            # fully exit the process
```

`tools\install-autostart.ps1 -Shortcuts` drops **Pause 1h / Resume / Off for today**
shortcuts on your Desktop so those are a double-click.

## If the PowerShell path is blocked

Corporate lockdown breaks execution paths in different ways. chlorophyll ships four
independent tiers; `doctor.ps1` names the highest one your machine allows:

1. **PS script** (primary) — needs `powershell.exe`. Blocked only by `AllSigned`
   policy or Constrained Language Mode.
2. **Encoded launcher** — `tools\make-encoded-launcher.ps1`; survives `AllSigned`
   because policy governs script *files*, not encoded commands.
3. **Prebuilt exe** — `tools\build-exe.ps1` on *this* machine, copy the one file
   over. Blocked only by AppLocker/WDAC.
4. **Compile-on-target** — `tools\build-exe.ps1` on the laptop itself.

The only setup that beats all four is WDAC + Constrained Language + unsigned-exe
blocking together. That's signing-enforced by design; the doctor says so plainly.

## Autostart / uninstall

```powershell
tools\install-autostart.ps1                 # Startup-folder shortcut (no admin)
tools\install-autostart.ps1 -ScheduledTask  # at-logon task in your user context
tools\install-autostart.ps1 -Uninstall      # remove everything it installed
```

Nothing is written outside `%LOCALAPPDATA%\chlorophyll` and your Startup folder, so
uninstall is complete and needs no admin.

## Configuration

Every key is documented in [`chlorophyll.conf.example`](chlorophyll.conf.example).
Copy it to `chlorophyll.conf` and edit. `chlorophyll.conf` is git-ignored.

## License

MIT — see [LICENSE](LICENSE).
