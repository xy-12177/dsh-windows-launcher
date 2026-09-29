# DeepSeek Harness Web GUI launcher -- windowless.
#
# GOALS
#   1. One desktop click reliably puts the harness UI in front of the user.
#   2. No console window is left on screen, ever.
#
# WHY IT LOOKS LIKE THIS
#
#  * The harness server IS the long-lived process, so "no resident window"
#    means the server must run with no window at all -- not `cmd /k`. We
#    therefore spawn node.exe on dsh's bin.js directly (the same argv dsh.cmd
#    builds) with -WindowStyle Hidden and both streams redirected into .run\.
#    Node's writes to a redirected FILE are synchronous, so the URL line is on
#    disk the instant it is printed; a pipe or Tee-Object would have buffered it.
#
#  * We pass --no-open and open the browser ourselves. dsh's own handoff calls
#    ShellExecute, and when Edge is already running that only appends a
#    background TAB to an existing window, which Windows' foreground lock then
#    refuses to raise -- the "two consoles and nothing else" symptom. Opening
#    `msedge --new-window` plus an explicit foreground grab is what makes the
#    UI actually appear.
#
#  * --no-open is only safe because we read dsh's own token URL back out of the
#    log. Opening the bare root URL would show 401: the browser cookie is
#    minted by exchanging the process launch token at `/?token=...`.
#
#  * The token stays valid for the life of the server process, so .run\state.json
#    caches it next to the server PID. A second click on the shortcut reuses it
#    and re-opens the UI instead of 401-ing or booting a doomed second instance.
#
#  * A windowless launcher cannot report failure by printing, so every failure
#    path ends in a MessageBox carrying the tail of the server log.
#
# Usage:  start-dsh.vbs (desktop shortcut)  |  powershell -File start-dsh.ps1
param(
    [int]$Port = 4080,
    [int]$WaitMs = 90000,
    [string]$WorkDir = '',
    [switch]$AppWindow
)

$ErrorActionPreference = 'Stop'

# install.ps1 writes dsh-launcher.json next to this script; explicit
# parameters still win over it. The working directory must NOT default to the
# launcher folder: dsh's sandbox stamps a Low integrity label on its workspace,
# and Explorer then refuses to load the shortcut icon stored there.
$configFile = Join-Path $PSScriptRoot 'dsh-launcher.json'
if (Test-Path -LiteralPath $configFile) {
    try {
        $cfg = Get-Content -LiteralPath $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $PSBoundParameters.ContainsKey('Port') -and $cfg.port) { $Port = [int]$cfg.port }
        if (-not $PSBoundParameters.ContainsKey('WorkDir') -and $cfg.workDir) { $WorkDir = [string]$cfg.workDir }
        if (-not $PSBoundParameters.ContainsKey('AppWindow') -and $cfg.appWindow) { $AppWindow = [switch]$true }
    } catch { }
}
if ([string]::IsNullOrWhiteSpace($WorkDir)) { $WorkDir = Join-Path $env:USERPROFILE 'dsh-workspace' }
if (-not (Test-Path -LiteralPath $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }

$runDir    = Join-Path $PSScriptRoot '.run'
$outLog    = Join-Path $runDir 'server.log'
$errLog    = Join-Path $runDir 'server.err'
$stateFile = Join-Path $runDir 'state.json'

# --- launch progress window -------------------------------------------------
# A small borderless card (logo, stage text, elapsed clock, progress bar) that
# appears right after the shortcut click and tracks the real startup stages
# below. It follows the system light/dark theme and paints crisply at any DPI. It is compiled as C# so that it can
# live on its own background STA thread with a real message pump: the launcher
# thread spends most of its time in Start-Sleep polling loops, and the window
# must keep painting and never show "Not Responding" during the up-to-90s
# readiness wait. No files are created; the window dies with this process.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

    // Borderless, owner-drawn progress card. Everything is painted in OnPaint so
    // it stays crisp at any DPI and follows the system light/dark app theme.
    // The form owns the elapsed-time clock and the bar easing/shimmer (a 16 ms
    // UI timer); the launcher only ever moves the target percent and the text.
    public class DshProgressForm : Form {
        [DllImport("dwmapi.dll")] private static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int val, int size);
        [DllImport("dwmapi.dll")] private static extern int DwmExtendFrameIntoClientArea(IntPtr h, ref Margins m);
        [StructLayout(LayoutKind.Sequential)] private struct Margins { public int L, R, T, B; }

        public string Title = "";
        public string Stage = "";
        public float Target;
        private float _shown;
        private float _phase;
        private readonly DateTime _start = DateTime.Now;
        private readonly Bitmap _logo;
        private readonly float _k;
        private readonly Color _bg, _fg, _sub, _track, _edge;
        private static readonly Color Accent1 = Color.FromArgb(92, 124, 255);
        private static readonly Color Accent2 = Color.FromArgb(52, 72, 222);
        private readonly Font _titleFont, _stageFont, _timeFont;
        private readonly System.Windows.Forms.Timer _tick;

        public DshProgressForm(string title, string stage, string logoPath) {
            Title = title; Stage = stage;
            bool dark = false;
            try {
                object v = Microsoft.Win32.Registry.GetValue(
                    @"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
                    "AppsUseLightTheme", 1);
                dark = v is int && (int)v == 0;
            } catch { }
            _bg    = dark ? Color.FromArgb(32, 33, 38)    : Color.FromArgb(255, 255, 255);
            _fg    = dark ? Color.FromArgb(240, 241, 245) : Color.FromArgb(24, 26, 34);
            _sub   = dark ? Color.FromArgb(160, 164, 176) : Color.FromArgb(104, 110, 124);
            _track = dark ? Color.FromArgb(52, 54, 62)    : Color.FromArgb(232, 235, 244);
            _edge  = dark ? Color.FromArgb(60, 62, 70)    : Color.FromArgb(222, 225, 232);

            if (!string.IsNullOrEmpty(logoPath) && File.Exists(logoPath)) {
                try {
                    using (MemoryStream ms = new MemoryStream(File.ReadAllBytes(logoPath)))
                    using (Image img = Image.FromStream(ms)) { _logo = new Bitmap(img); }
                } catch { _logo = null; }
            }

            using (Graphics g = CreateGraphics()) { _k = g.DpiX / 96f; }
            string face = "Microsoft YaHei UI";
            _titleFont = new Font(face, 11.5f, FontStyle.Bold);
            _stageFont = new Font(face, 9f);
            _timeFont  = new Font("Segoe UI Semibold", 10f);

            Text = title;
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            TopMost = true;
            StartPosition = FormStartPosition.Manual;
            BackColor = _bg;
            ClientSize = new Size(S(440), S(124));
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);

            _tick = new System.Windows.Forms.Timer();
            _tick.Interval = 16;
            _tick.Tick += delegate(object s, EventArgs e) {
                _shown += (Target - _shown) * 0.12f;
                if (Math.Abs(Target - _shown) < 0.05f) { _shown = Target; }
                _phase += 0.012f;
                if (_phase > 1.6f) { _phase = -0.6f; }
                Invalidate();
            };
            _tick.Start();
        }

        private int S(float v) { return (int)Math.Round(v * _k); }

        protected override CreateParams CreateParams {
            get {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x80;          // WS_EX_TOOLWINDOW: keep out of Alt-Tab
                return cp;
            }
        }

        protected override void OnHandleCreated(EventArgs e) {
            base.OnHandleCreated(e);
            // Windows 11: native rounded corners + DWM shadow on a borderless window.
            // On older systems both calls fail harmlessly and the card is square.
            try {
                int round = 2;               // DWMWCP_ROUND
                DwmSetWindowAttribute(Handle, 33, ref round, 4);
                int policy = 2;              // DWMNCRP_ENABLED, needed for the shadow
                DwmSetWindowAttribute(Handle, 2, ref policy, 4);
                Margins m = new Margins(); m.L = 0; m.R = 0; m.T = 0; m.B = 1;
                DwmExtendFrameIntoClientArea(Handle, ref m);
                int border = ColorTranslator.ToWin32(_edge);
                DwmSetWindowAttribute(Handle, 34, ref border, 4);   // DWMWA_BORDER_COLOR
            } catch { }
        }

        // Handle is created before Show, which defeats CenterScreen; centre by hand
        // on the monitor under the cursor (where the shortcut was just clicked).
        protected override void OnLoad(EventArgs e) {
            base.OnLoad(e);
            Rectangle wa = Screen.FromPoint(Cursor.Position).WorkingArea;
            Location = new Point(wa.X + (wa.Width - Width) / 2, wa.Y + (wa.Height - Height) / 2);
        }

        private static GraphicsPath Pill(RectangleF r) {
            GraphicsPath p = new GraphicsPath();
            float d = r.Height;
            if (r.Width < d) { r.Width = d; }
            p.AddArc(r.X, r.Y, d, d, 90, 180);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 180);
            p.CloseFigure();
            return p;
        }

        protected override void OnPaint(PaintEventArgs e) {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.Clear(_bg);

            int pad = S(22);
            int logo = S(44);
            if (_logo != null) { g.DrawImage(_logo, new Rectangle(pad - S(2), S(20), logo, logo)); }
            int tx = _logo != null ? pad + logo + S(12) : pad;

            TimeSpan el = DateTime.Now - _start;
            string time = string.Format("{0}:{1:00}", (int)el.TotalMinutes, el.Seconds);
            SizeF ts = g.MeasureString(time, _timeFont);
            float timeX = ClientSize.Width - pad - ts.Width;

            using (SolidBrush fg = new SolidBrush(_fg))
            using (SolidBrush sub = new SolidBrush(_sub)) {
                g.DrawString(Title, _titleFont, fg, tx - S(2), S(20));
                RectangleF stageRect = new RectangleF(tx - S(1), S(46), timeX - tx, S(22));
                using (StringFormat sf = new StringFormat(StringFormatFlags.NoWrap)) {
                    sf.Trimming = StringTrimming.EllipsisCharacter;
                    g.DrawString(Stage, _stageFont, sub, stageRect, sf);
                }
                g.DrawString(time, _timeFont, sub, timeX, S(22));
            }

            // Progress bar: rounded track, gradient fill, travelling highlight.
            RectangleF track = new RectangleF(pad, S(88), ClientSize.Width - 2 * pad, S(6));
            using (GraphicsPath tp = Pill(track))
            using (SolidBrush tb = new SolidBrush(_track)) { g.FillPath(tb, tp); }
            float w = track.Width * Math.Max(0f, Math.Min(100f, _shown)) / 100f;
            if (w > 0.5f) {
                RectangleF fill = new RectangleF(track.X, track.Y, Math.Max(w, track.Height), track.Height);
                using (GraphicsPath fp = Pill(fill)) {
                    using (LinearGradientBrush lb = new LinearGradientBrush(
                               new RectangleF(track.X - 1, track.Y, track.Width + 2, track.Height),
                               Accent1, Accent2, LinearGradientMode.Horizontal)) {
                        g.FillPath(lb, fp);
                    }
                    if (_shown < 99.5f) {
                        float bw = track.Width * 0.22f;
                        float bx = track.X + _phase * track.Width - bw / 2;
                        RectangleF band = new RectangleF(bx, track.Y, bw, track.Height);
                        Region old = g.Clip;
                        g.SetClip(fp, CombineMode.Intersect);
                        using (LinearGradientBrush sb = new LinearGradientBrush(
                                   new RectangleF(bx - 1, track.Y, bw + 2, track.Height),
                                   Color.FromArgb(0, 255, 255, 255), Color.FromArgb(0, 255, 255, 255),
                                   LinearGradientMode.Horizontal)) {
                            ColorBlend cb = new ColorBlend(3);
                            cb.Colors = new Color[] { Color.FromArgb(0, 255, 255, 255), Color.FromArgb(150, 255, 255, 255), Color.FromArgb(0, 255, 255, 255) };
                            cb.Positions = new float[] { 0f, 0.5f, 1f };
                            sb.InterpolationColors = cb;
                            g.FillRectangle(sb, band);
                        }
                        g.Clip = old;
                    }
                }
            }
        }

        protected override void OnFormClosed(FormClosedEventArgs e) {
            _tick.Stop();
            base.OnFormClosed(e);
        }
    }

    // Launch-progress window. It lives on its own background STA thread with a
    // real message pump (Application.Run), so it keeps painting while the
    // launcher thread blocks in Start-Sleep polling loops and never shows
    // "Not Responding" during the up-to-90s readiness wait. The launcher only
    // calls the static methods below; each update is marshalled onto the
    // window thread via BeginInvoke, which is safe from any thread.
    public static class DshProgress {
        [DllImport("user32.dll")] private static extern bool SetProcessDPIAware();
        private static DshProgressForm _form;
        private static Thread _thread;
        private static readonly object _lock = new object();
        private static readonly ManualResetEvent _ready = new ManualResetEvent(false);

        // Create the window on its own STA thread and wait until it exists.
        // Returns false when no window could be created within 5 seconds.
        public static bool Show(string title, string stage, string logoPath) {
            lock (_lock) {
                if (_thread != null) { return true; }
                _ready.Reset();
                _thread = new Thread(delegate() {
                    try { SetProcessDPIAware(); } catch { }
                    Application.EnableVisualStyles();
                    DshProgressForm f = new DshProgressForm(title, stage, logoPath);
                    // Create the handle before the form is published: once Show's
                    // _ready gate opens, callers may BeginInvoke immediately, and
                    // BeginInvoke on a handle-less control throws.
                    IntPtr h = f.Handle;
                    _form = f;
                    _ready.Set();
                    Application.Run(f);
                });
                _thread.SetApartmentState(ApartmentState.STA);
                _thread.IsBackground = true;
                _thread.Start();
            }
            return _ready.WaitOne(5000);
        }

        // Thread-safe update: the launcher thread posts, the window thread applies.
        public static void SetStage(int percent, string stage) {
            DshProgressForm f;
            lock (_lock) { f = _form; }
            if (f == null || f.IsDisposed) { return; }
            float p = percent < 0 ? 0 : (percent > 100 ? 100 : percent);
            f.BeginInvoke((MethodInvoker)delegate() {
                f.Target = p;
                f.Stage = stage;
                f.Invalidate();
            });
        }

        // Close the window and wait briefly for its thread to finish.
        public static void Close() {
            DshProgressForm f;
            Thread t;
            lock (_lock) { f = _form; t = _thread; _form = null; }
            if (f == null) { return; }
            f.BeginInvoke((MethodInvoker)delegate() { f.Close(); });
            if (t != null && t != Thread.CurrentThread) { t.Join(3000); }
        }
    }
"@ -ReferencedAssemblies @('System.Windows.Forms.dll','System.Drawing.dll')

function Show-ProgressWindow {
    param([string]$Stage)
    # Fail loudly if the window cannot appear: a silent no-window launch would
    # regress the whole point of this file.
    $logo = Join-Path $PSScriptRoot 'deepseek-logo.png'
    if (-not [DshProgress]::Show('DeepSeek Harness', $Stage, $logo)) {
        throw 'The progress window failed to appear.'
    }
}

# --- failure reporting ------------------------------------------------------
function Show-Failure {
    param([string]$Message)
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show(
            $Message, 'DeepSeek Harness',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error)
    } catch {
        try { (New-Object -ComObject WScript.Shell).Popup($Message, 0, 'DeepSeek Harness', 16) } catch { }
    }
}

# Read a file the server still holds open.
function Read-SharedText {
    param([string]$Path, [int]$TailChars = 0)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $text = ''
    try {
        $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
        try {
            $sr = New-Object System.IO.StreamReader($fs)
            try { $text = $sr.ReadToEnd() } finally { $sr.Dispose() }
        } finally { $fs.Dispose() }
    } catch { return '' }
    if ($TailChars -gt 0 -and $text.Length -gt $TailChars) { return $text.Substring($text.Length - $TailChars) }
    return $text
}

# --- native window handling -------------------------------------------------
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class DshFg {
    private delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] private static extern int  GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] private static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);

    public static IntPtr[] WindowsOf(int[] pids) {
        List<IntPtr> found = new List<IntPtr>();
        HashSet<uint> want = new HashSet<uint>();
        foreach (int p in pids) { want.Add((uint)p); }
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            if (IsWindowVisible(h) && GetWindowTextLength(h) > 0) {
                uint pid; GetWindowThreadProcessId(h, out pid);
                if (want.Contains(pid)) { found.Add(h); }
            }
            return true;
        }, IntPtr.Zero);
        return found.ToArray();
    }

    // A synthetic ALT tap clears the foreground lock that would otherwise pin
    // a window spawned by a background process behind everything else.
    public static void Raise(IntPtr h) {
        if (IsIconic(h)) { ShowWindow(h, 9); }
        keybd_event(0x12, 0, 0, UIntPtr.Zero);
        keybd_event(0x12, 0, 0x0002, UIntPtr.Zero);
        SetForegroundWindow(h);
    }
}
"@

function Get-EdgeWindowHandles {
    $edgePids = @(Get-Process -Name msedge -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
    if ($edgePids.Count -eq 0) { return @() }
    return @([DshFg]::WindowsOf([int[]]$edgePids))
}

function Resolve-Edge {
    $candidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe')
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe'
    try {
        $p = (Get-ItemProperty -Path $key -ErrorAction Stop).'(default)'
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    } catch { }
    return $null
}

# Open the UI and make sure the user actually sees it.
function Open-Ui {
    param([string]$Url)
    $before = @{}
    foreach ($h in (Get-EdgeWindowHandles)) { $before[$h] = $true }

    $edge = Resolve-Edge
    if ($null -eq $edge) {
        Start-Process $Url          # no Edge installed: fall back to the default browser
        return
    }
    if ($AppWindow) { $edgeArgs = @("--app=$Url") } else { $edgeArgs = @('--new-window', $Url) }
    Start-Process -FilePath $edge -ArgumentList $edgeArgs

    # Wait for the window Edge is about to create, then take the foreground.
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 200
        foreach ($h in (Get-EdgeWindowHandles)) {
            if (-not $before.ContainsKey($h)) { [DshFg]::Raise($h); return }
        }
    }
    # No new top-level window appeared (Edge reused one). Raise what it has.
    $any = @(Get-EdgeWindowHandles)
    if ($any.Count -gt 0) { [DshFg]::Raise($any[0]) }
}

function Test-PortListening {
    param([int]$PortNumber, [int]$TimeoutMs = 500)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect('127.0.0.1', $PortNumber, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($iar)
        return $true
    } catch {
        return $false
    } finally {
        try { $client.Close() } catch { }
    }
}

function Get-PortOwnerPid {
    param([int]$PortNumber)
    try {
        $c = Get-NetTCPConnection -LocalPort $PortNumber -State Listen -ErrorAction Stop | Select-Object -First 1
        if ($null -ne $c) { return [int]$c.OwningProcess }
    } catch { }
    return 0
}

try {
    # --- launch progress window ---------------------------------------------
    Show-ProgressWindow -Stage '正在启动…'

    if (-not (Test-Path -LiteralPath $runDir)) { New-Item -ItemType Directory -Path $runDir -Force | Out-Null }

    # --- Case 1: a harness is already serving --------------------------------
    [DshProgress]::SetStage(5, '正在检查是否已有实例运行…')
    if (Test-PortListening -PortNumber $Port) {
        $ownerPid = Get-PortOwnerPid -PortNumber $Port
        $cachedUrl = ''
        if (Test-Path -LiteralPath $stateFile) {
            try {
                $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
                if ($state.port -eq $Port -and $ownerPid -ne 0 -and [int]$state.pid -eq $ownerPid) {
                    $cachedUrl = [string]$state.url
                }
            } catch { }
        }
        if ([string]::IsNullOrWhiteSpace($cachedUrl)) {
            # Someone else owns the port. Edge may still hold a valid cookie;
            # if it does not, it shows 401, which is the honest state of things.
            $cachedUrl = "http://127.0.0.1:$Port/"
        }
        [DshProgress]::SetStage(90, '已在运行，正在打开浏览器…')
        Open-Ui -Url $cachedUrl
        [DshProgress]::SetStage(100, '完成')
        [DshProgress]::Close()
        exit 0
    }

    # --- Case 2: cold boot ----------------------------------------------------
    $nodeExe = $null
    $nodeCmd = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($null -ne $nodeCmd) { $nodeExe = $nodeCmd.Source }
    if ($null -eq $nodeExe) {
        foreach ($c in @((Join-Path $env:ProgramFiles 'nodejs\node.exe'), (Join-Path ${env:ProgramFiles(x86)} 'nodejs\node.exe'))) {
            if (Test-Path -LiteralPath $c) { $nodeExe = $c; break }
        }
    }
    $binJs = Join-Path $env:APPDATA 'npm\node_modules\@deepseek-ai\dsh\lib\bin.js'

    Remove-Item -LiteralPath $outLog, $errLog -Force -ErrorAction SilentlyContinue

    if ($null -ne $nodeExe -and (Test-Path -LiteralPath $binJs)) {
        $file = $nodeExe
        $argv = @($binJs, 'web', '--port', "$Port", '--no-open')
    } else {
        # No direct node/bin.js: go through dsh.cmd, still windowless.
        $file = 'cmd.exe'
        $argv = @('/c', 'dsh', 'web', '--port', "$Port", '--no-open')
    }

    [DshProgress]::SetStage(30, '正在启动服务…')
    $proc = Start-Process -FilePath $file -ArgumentList $argv `
        -WorkingDirectory $WorkDir -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $outLog -RedirectStandardError $errLog

    # Wait for dsh's own token URL line, not merely for the bind: the URL is
    # printed from announceReady, after the plugin loader settles.
    $pattern = "http://127\.0\.0\.1:$Port/\?token=[A-Za-z0-9_\-]+"
    $url = ''
    $deadline = (Get-Date).AddMilliseconds($WaitMs)
    [DshProgress]::SetStage(45, '等待服务就绪…')
    while ((Get-Date) -lt $deadline) {
        $m = [regex]::Match((Read-SharedText -Path $outLog), $pattern)
        if ($m.Success) { $url = $m.Value; break }
        if ($proc.HasExited) { break }
        # The window runs its own elapsed clock and shimmer, so it reads as
        # alive during a wait that can last 90s; the bar itself only moves on
        # stage transitions (never on a timer).
        Start-Sleep -Milliseconds 200
    }

    if ([string]::IsNullOrWhiteSpace($url)) {
        $tail = (Read-SharedText -Path $outLog -TailChars 1200).Trim()
        $tailErr = (Read-SharedText -Path $errLog -TailChars 1200).Trim()
        $why = "The harness did not report a URL within $([int]($WaitMs / 1000))s."
        if ($proc.HasExited) { $why = "The harness process exited with code $($proc.ExitCode)." }
        [DshProgress]::Close()
        Show-Failure ($why + "`r`n`r`nLogs: $runDir`r`n`r`n--- server.log ---`r`n$tail`r`n`r`n--- server.err ---`r`n$tailErr")
        exit 1
    }

    @{ pid = $proc.Id; port = $Port; url = $url; started = (Get-Date).ToString('o') } |
        ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding UTF8

    [DshProgress]::SetStage(90, '正在打开浏览器…')
    Open-Ui -Url $url
    [DshProgress]::SetStage(100, '完成')
    [DshProgress]::Close()
    exit 0
} catch {
    [DshProgress]::Close()
    Show-Failure ("The launcher failed before the harness could start.`r`n`r`n" + $_.Exception.Message + "`r`n`r`n" + $_.ScriptStackTrace)
    exit 1
}
