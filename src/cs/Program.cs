// chlorophyll - exe fallback (tiers 3 & 4).
//
// Same behavior and same config/command/status files as the PowerShell path, so
// the two are interchangeable. Compiled with the csc.exe that ships inside
// Windows (.NET Framework 4.x) - see tools\build-exe.ps1. Built /target:winexe so
// there is no console window at all.
//
// Usage:
//   chlorophyll.exe            run the loop (headless)
//   chlorophyll.exe once       one nudge and exit (smoke test)
//   chlorophyll.exe status     print current status and exit
//   chlorophyll.exe stop|pause|resume|toggle|off|pausefor <min>
//
// It reads the same limits documented in README.md. Injected input is flagged
// LLKHF_INJECTED; this tool does not hide that.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace Chlorophyll
{
    internal static class Native
    {
        [DllImport("user32.dll")]
        internal static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
        [DllImport("user32.dll")]
        internal static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);

        [StructLayout(LayoutKind.Sequential)]
        internal struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
        [DllImport("user32.dll")]
        internal static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
        [DllImport("kernel32.dll")]
        internal static extern uint GetTickCount();
        [DllImport("kernel32.dll")]
        internal static extern uint SetThreadExecutionState(uint esFlags);

        internal const byte VK_F15 = 0x7E;
        internal const byte VK_SCROLL = 0x91;
        internal const uint KEYEVENTF_KEYUP = 0x0002;
        internal const uint MOUSEEVENTF_MOVE = 0x0001;
        internal const uint ES_CONTINUOUS = 0x80000000;
        internal const uint ES_SYSTEM_REQUIRED = 0x00000001;
        internal const uint ES_DISPLAY_REQUIRED = 0x00000002;

        internal static int IdleSeconds()
        {
            var lii = new LASTINPUTINFO { cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO)) };
            if (!GetLastInputInfo(ref lii)) return 0;
            uint delta = unchecked(GetTickCount() - lii.dwTime); // handles wraparound
            return (int)(delta / 1000);
        }

        internal static void Nudge(string method)
        {
            var none = UIntPtr.Zero;
            switch (method)
            {
                case "ScrollLock":
                    for (int i = 0; i < 2; i++)
                    {
                        keybd_event(VK_SCROLL, 0, 0, none);
                        keybd_event(VK_SCROLL, 0, KEYEVENTF_KEYUP, none);
                    }
                    break;
                case "MouseJiggle":
                    mouse_event(MOUSEEVENTF_MOVE, 0, 0, 0, none);
                    break;
                default: // F15
                    keybd_event(VK_F15, 0, 0, none);
                    keybd_event(VK_F15, 0, KEYEVENTF_KEYUP, none);
                    break;
            }
        }
    }

    // Minimal INI parser + typed accessors. Mirrors Config.psm1 defaults exactly.
    internal sealed class Config
    {
        public List<string> WorkDays = new List<string> { "Mon", "Tue", "Wed", "Thu", "Fri" };
        public string WorkStart = "08:00";
        public string WorkEnd = "17:30";
        public string LunchStart = "12:00";
        public int LunchMinutes = 45;
        public int LunchJitterMinutes = 15;
        public string NudgeMethod = "F15";
        public int MinIntervalSec = 30;
        public int MaxIntervalSec = 90;
        public int NudgeAfterIdleSeconds = 45;
        public bool PreventLock = true;
        public bool PreventDisplayOff = true;
        public string LogLevel = "Info";

        public static Config Load(string path)
        {
            var c = new Config();
            if (string.IsNullOrEmpty(path) || !File.Exists(path)) return c;
            foreach (var raw in File.ReadAllLines(path))
            {
                var line = raw.Trim();
                if (line.Length == 0 || line[0] == '#' || line[0] == ';') continue;
                int eq = line.IndexOf('=');
                if (eq < 1) continue;
                string k = line.Substring(0, eq).Trim();
                string v = line.Substring(eq + 1).Trim();
                try { Apply(c, k, v); } catch { /* keep default on bad value */ }
            }
            return c;
        }

        private static void Apply(Config c, string k, string v)
        {
            switch (k)
            {
                case "WorkDays":
                    c.WorkDays = new List<string>(v.Split(','));
                    c.WorkDays = c.WorkDays.ConvertAll(s => s.Trim());
                    break;
                case "WorkStart": c.WorkStart = v; break;
                case "WorkEnd": c.WorkEnd = v; break;
                case "LunchStart": c.LunchStart = v; break;
                case "LunchMinutes": c.LunchMinutes = int.Parse(v); break;
                case "LunchJitterMinutes": c.LunchJitterMinutes = int.Parse(v); break;
                case "NudgeMethod": c.NudgeMethod = v; break;
                case "MinIntervalSec": c.MinIntervalSec = int.Parse(v); break;
                case "MaxIntervalSec": c.MaxIntervalSec = int.Parse(v); break;
                case "NudgeAfterIdleSeconds": c.NudgeAfterIdleSeconds = int.Parse(v); break;
                case "PreventLock": c.PreventLock = ParseBool(v); break;
                case "PreventDisplayOff": c.PreventDisplayOff = ParseBool(v); break;
                case "LogLevel": c.LogLevel = v; break;
            }
        }

        private static bool ParseBool(string v)
        {
            v = v.Trim().ToLowerInvariant();
            return v == "true" || v == "1" || v == "yes" || v == "on";
        }

        public static int Minutes(string hhmm)
        {
            var parts = hhmm.Split(':');
            return int.Parse(parts[0]) * 60 + int.Parse(parts[1]);
        }
    }

    internal static class Schedule
    {
        private static readonly Dictionary<DayOfWeek, string> Abbrev = new Dictionary<DayOfWeek, string>
        {
            { DayOfWeek.Sunday,"Sun"},{DayOfWeek.Monday,"Mon"},{DayOfWeek.Tuesday,"Tue"},
            { DayOfWeek.Wednesday,"Wed"},{DayOfWeek.Thursday,"Thu"},{DayOfWeek.Friday,"Fri"},{DayOfWeek.Saturday,"Sat"}
        };

        private static int DailyJitter(DateTime date, int jitter)
        {
            if (jitter <= 0) return 0;
            int seed = (int)(date.Date.Ticks >> 32) ^ date.DayOfYear ^ date.Year;
            int span = 2 * jitter + 1;
            return (Math.Abs(seed) % span) - jitter;
        }

        internal static bool InWorkWindow(DateTime now, Config c)
        {
            if (!c.WorkDays.Contains(Abbrev[now.DayOfWeek])) return false;
            int mins = now.Hour * 60 + now.Minute;
            if (mins < Config.Minutes(c.WorkStart) || mins >= Config.Minutes(c.WorkEnd)) return false;

            if (!string.IsNullOrWhiteSpace(c.LunchStart) && c.LunchMinutes > 0)
            {
                int baseMin = Config.Minutes(c.LunchStart) + DailyJitter(now, c.LunchJitterMinutes);
                DateTime start = now.Date.AddMinutes(baseMin);
                DateTime end = start.AddMinutes(c.LunchMinutes);
                if (now >= start && now < end) return false;
            }
            return true;
        }

        internal static DateTime NextWorkStart(DateTime now, Config c)
        {
            int startMin = Config.Minutes(c.WorkStart);
            for (int i = 0; i <= 14; i++)
            {
                DateTime day = now.Date.AddDays(i);
                DateTime cand = day.AddMinutes(startMin);
                if (cand <= now) continue;
                if (c.WorkDays.Contains(Abbrev[day.DayOfWeek])) return cand;
            }
            return now.Date.AddDays(1).AddMinutes(startMin);
        }
    }

    internal static class Program
    {
        private static string DataDir()
        {
            string b = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            string d = Path.Combine(b, "chlorophyll");
            Directory.CreateDirectory(d);
            return d;
        }
        private static string CommandFile() { return Path.Combine(DataDir(), "command"); }
        private static string StatusFile() { return Path.Combine(DataDir(), "status"); }
        private static string ConfPath()
        {
            // build\chlorophyll.exe -> repo root is one level up; also try cwd.
            string exeDir = AppDomain.CurrentDomain.BaseDirectory;
            string guess = Path.Combine(Path.GetFullPath(Path.Combine(exeDir, "..")), "chlorophyll.conf");
            if (File.Exists(guess)) return guess;
            return Path.Combine(Directory.GetCurrentDirectory(), "chlorophyll.conf");
        }

        [STAThread]
        private static int Main(string[] args)
        {
            string verb = args.Length > 0 ? args[0].ToLowerInvariant() : "start";
            switch (verb)
            {
                case "stop": case "pause": case "resume": case "toggle": case "off":
                    File.WriteAllText(CommandFile(), Capitalize(verb));
                    return 0;
                case "pausefor":
                    string mins = args.Length > 1 ? args[1] : "60";
                    File.WriteAllText(CommandFile(), "PauseFor:" + mins);
                    return 0;
                case "status":
                    Console.WriteLine(File.Exists(StatusFile()) ? File.ReadAllText(StatusFile()) : "chlorophyll: not running.");
                    return 0;
                case "once":
                {
                    var cfg0 = Config.Load(ConfPath());
                    Native.Nudge(cfg0.NudgeMethod);
                    return 0;
                }
                default:
                    return RunLoop();
            }
        }

        private static string Capitalize(string s) { return char.ToUpper(s[0]) + s.Substring(1); }

        private static int RunLoop()
        {
            bool createdNew;
            using (var mutex = new Mutex(true, "Local\\chlorophyll_singleton", out createdNew))
            {
                if (!createdNew) return 0; // already running

                var cfg = Config.Load(ConfPath());
                var rng = new Random();
                string mode = "Active";
                DateTime? resumeAt = null;
                string reason = "";
                DateTime? lastNudge = null;
                bool holdOn = false;

                try
                {
                    while (true)
                    {
                        // consume command
                        string cf = CommandFile();
                        if (File.Exists(cf))
                        {
                            string cmd = File.ReadAllText(cf).Trim();
                            try { File.Delete(cf); } catch { }
                            if (cmd == "Stop") break;
                            else if (cmd == "Pause") { mode = "Paused"; resumeAt = null; reason = "manual"; }
                            else if (cmd == "Resume") { mode = "Active"; resumeAt = null; reason = ""; }
                            else if (cmd == "Toggle")
                            {
                                if (mode == "Active") { mode = "Paused"; resumeAt = null; reason = "manual"; }
                                else { mode = "Active"; resumeAt = null; reason = ""; }
                            }
                            else if (cmd == "Off") { mode = "Paused"; resumeAt = Schedule.NextWorkStart(DateTime.Now, cfg); reason = "offday"; }
                            else if (cmd.StartsWith("PauseFor:"))
                            {
                                int m; if (int.TryParse(cmd.Substring(9), out m)) { mode = "Paused"; resumeAt = DateTime.Now.AddMinutes(m); reason = "timed"; }
                            }
                        }

                        DateTime now = DateTime.Now;
                        if (mode == "Paused" && resumeAt.HasValue && now >= resumeAt.Value) { mode = "Active"; resumeAt = null; reason = ""; }

                        bool inWindow = Schedule.InWorkWindow(now, cfg);
                        bool active = mode == "Active" && inWindow;

                        int idle = 0;
                        if (active)
                        {
                            if (!holdOn && (cfg.PreventLock || cfg.PreventDisplayOff))
                            {
                                uint flags = Native.ES_CONTINUOUS;
                                if (cfg.PreventLock) flags |= Native.ES_SYSTEM_REQUIRED;
                                if (cfg.PreventDisplayOff) flags |= Native.ES_DISPLAY_REQUIRED;
                                Native.SetThreadExecutionState(flags);
                                holdOn = true;
                            }
                            idle = Native.IdleSeconds();
                            if (idle >= cfg.NudgeAfterIdleSeconds) { Native.Nudge(cfg.NudgeMethod); lastNudge = DateTime.Now; }
                        }
                        else if (holdOn)
                        {
                            Native.SetThreadExecutionState(Native.ES_CONTINUOUS);
                            holdOn = false;
                        }

                        int interval = active
                            ? (cfg.MaxIntervalSec > cfg.MinIntervalSec ? rng.Next(cfg.MinIntervalSec, cfg.MaxIntervalSec + 1) : cfg.MinIntervalSec)
                            : 60;

                        WriteStatus(mode, reason, resumeAt, inWindow, idle, lastNudge, now.AddSeconds(interval));
                        Thread.Sleep(interval * 1000);
                    }
                }
                finally
                {
                    if (holdOn) Native.SetThreadExecutionState(Native.ES_CONTINUOUS);
                    try { File.Delete(StatusFile()); } catch { }
                }
                return 0;
            }
        }

        private static void WriteStatus(string mode, string reason, DateTime? resumeAt, bool inWindow,
            int idle, DateTime? lastNudge, DateTime nextWake)
        {
            var sb = new StringBuilder();
            sb.AppendLine("Pid=" + Process.GetCurrentProcess().Id);
            sb.AppendLine("Mode=" + mode);
            sb.AppendLine("Reason=" + reason);
            sb.AppendLine("ResumeAt=" + (resumeAt.HasValue ? resumeAt.Value.ToString("s", CultureInfo.InvariantCulture) : ""));
            sb.AppendLine("InWindow=" + inWindow);
            sb.AppendLine("IdleSeconds=" + idle);
            sb.AppendLine("LastNudge=" + (lastNudge.HasValue ? lastNudge.Value.ToString("s", CultureInfo.InvariantCulture) : ""));
            sb.AppendLine("NextWake=" + nextWake.ToString("s", CultureInfo.InvariantCulture));
            sb.AppendLine("UpdatedAt=" + DateTime.Now.ToString("s", CultureInfo.InvariantCulture));
            try { File.WriteAllText(StatusFile(), sb.ToString()); } catch { }
        }
    }
}
