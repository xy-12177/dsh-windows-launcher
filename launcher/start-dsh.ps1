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
    [switch]$AppWindow,
    [switch]$Preview,
    [switch]$StaticMascot,
    [int]$PreviewSeconds = 12
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

$runDir    = Join-Path $PSScriptRoot '.run'
$outLog    = Join-Path $runDir 'server.log'
$errLog    = Join-Path $runDir 'server.err'
$stateFile = Join-Path $runDir 'state.json'

# --- launch progress window -------------------------------------------------
# A shaped 760x360 card (DeepSeek logo, product name, static whale-maid,
# stage text, elapsed clock, progress bar) that appears before startup begins.
# It follows the system light/dark theme and scales to DPI. It is compiled as C# so that it can
# live on its own background STA thread with a real message pump: the launcher
# thread spends most of its time in Start-Sleep polling loops, and the window
# must keep painting and never show "Not Responding" during the up-to-90s
# readiness wait. The optional -Preview path exercises the window only and
# returns before creating a workspace or run-state files.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

public class DshProgressForm : Form {
    [DllImport("dwmapi.dll")] private static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int val, int size);
    [DllImport("dwmapi.dll")] private static extern int DwmExtendFrameIntoClientArea(IntPtr h, ref Margins m);
    [StructLayout(LayoutKind.Sequential)] private struct Margins { public int L, R, T, B; }

    public string Title = "";
    public string Stage = "";
    private int _shown;
    private int _lastSecond = -1;
    private string _lastTimeText = "";
    private readonly DateTime _start = DateTime.Now;
    private readonly Bitmap _logo, _mascot, _wordmark;
    private Bitmap _background;
    private Bitmap _stageArt, _timeArt;
    private float _stageInkRight;
    private float _dotPhase;
    private bool _isLoading;
    private Rectangle _dotBounds = Rectangle.Empty;
    private readonly float _k;
    private readonly Color _bg, _bgEnd, _track, _edge;
    private readonly bool _dark;
    private static readonly Color Accent1 = Color.FromArgb(92, 124, 255);
    private static readonly Color Accent2 = Color.FromArgb(140, 109, 236);
    private readonly System.Windows.Forms.Timer _tick;
    private Size _regionSize = Size.Empty;
    private bool _updatingRegion;

    public DshProgressForm(string title, string stage, string logoPath, string mascotPath) {
        Title = title; Stage = stage;
        bool dark = false;
        try {
            object v = Microsoft.Win32.Registry.GetValue(
                @"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
                "AppsUseLightTheme", 1);
            dark = v is int && (int)v == 0;
        } catch { }
        _dark = dark;
        _bg = dark ? Color.FromArgb(34, 36, 44) : Color.FromArgb(255, 255, 255);
        _bgEnd = dark ? Color.FromArgb(40, 43, 54) : Color.FromArgb(246, 249, 255);
        _track = dark ? Color.FromArgb(61, 64, 76) : Color.FromArgb(229, 234, 245);
        _edge = dark ? Color.FromArgb(63, 67, 80) : Color.FromArgb(231, 235, 244);
        // Read system DPI without creating this Form's HWND. CreateGraphics()
        // here fires OnHandleCreated before the final ClientSize is assigned.
        using (Graphics g = Graphics.FromHwnd(IntPtr.Zero)) { _k = g.DpiX / 96f; }

        _logo = LoadFitted(logoPath, S(42), S(42));
        _mascot = LoadFitted(mascotPath, S(307), S(348));
        if (_mascot == null && !string.IsNullOrEmpty(mascotPath))
            _mascot = LoadFitted(Path.Combine(Path.GetDirectoryName(mascotPath) ?? "", "deepseek-logo.png"), S(307), S(348));

        Text = title;
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        BackColor = _bg;
        ClientSize = new Size(S(760), S(360));
        _wordmark = BuildWordmark(Title, S(340), S(49), dark);
        string displayStage = NormalizeStage(Stage);
        _isLoading = !IsTerminalStage(0, displayStage);
        _stageArt = BuildFooterArtwork(displayStage, S(430), S(36), S(24), dark, false, _isLoading, out _stageInkRight);
        _dotBounds = GetDotBounds();
        UpdateTimeArtwork();
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
                 ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        _background = BuildBackground(ClientSize.Width, ClientSize.Height);
        _tick = new System.Windows.Forms.Timer();
        _tick.Interval = 100;
        _tick.Tick += delegate(object s, EventArgs e) {
            int second = (int)(DateTime.Now - _start).TotalSeconds;
            if (second != _lastSecond) {
                _lastSecond = second;
                UpdateTimeArtwork();
            }
            if (_isLoading) {
                _dotPhase += 0.42f;
                if (_dotPhase >= (float)(Math.PI * 2.0)) _dotPhase -= (float)(Math.PI * 2.0);
                if (!_dotBounds.IsEmpty) Invalidate(_dotBounds);
            }
        };
        _tick.Start();
    }

    private int S(float v) { return (int)Math.Round(v * _k); }

    private static Bitmap LoadFitted(string path, int width, int height) {
        if (string.IsNullOrEmpty(path) || !File.Exists(path)) return null;
        try {
            using (MemoryStream ms = new MemoryStream(File.ReadAllBytes(path)))
            using (Image source = Image.FromStream(ms)) {
                Bitmap result = new Bitmap(width, height, System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
                using (Graphics g = Graphics.FromImage(result)) {
                    g.Clear(Color.Transparent);
                    g.CompositingMode = CompositingMode.SourceCopy;
                    g.CompositingQuality = CompositingQuality.HighQuality;
                    g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                    g.SmoothingMode = SmoothingMode.HighQuality;
                    float scale = Math.Min((float)width / source.Width, (float)height / source.Height);
                    int dw = (int)Math.Round(source.Width * scale), dh = (int)Math.Round(source.Height * scale);
                    g.DrawImage(source, new Rectangle((width-dw)/2, (height-dh)/2, dw, dh));
                }
                return result;
            }
        } catch { return null; }
    }

    private static Bitmap BuildWordmark(string text, int width, int height, bool dark) {
        Bitmap bitmap = new Bitmap(width, height, System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
        try {
            using (Graphics g = Graphics.FromImage(bitmap)) {
                g.Clear(Color.Transparent);
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                string[] candidates = new string[] { "Segoe Print", "Segoe Script", "Segoe UI" };
                GraphicsPath glyphs = null;
                FontFamily family = null;
                RectangleF bounds = RectangleF.Empty;
                try {
                    foreach (string candidate in candidates) {
                        try {
                            family = new FontFamily(candidate);
                            glyphs = new GraphicsPath();
                            glyphs.AddString(text, family, (int)FontStyle.Bold, 40f, PointF.Empty, StringFormat.GenericDefault);
                            bounds = glyphs.GetBounds();
                            if (bounds.Width > 0.1f && bounds.Height > 0.1f) break;
                            glyphs.Dispose(); glyphs = null; family.Dispose(); family = null;
                        } catch {
                            if (glyphs != null) { glyphs.Dispose(); glyphs = null; }
                            if (family != null) { family.Dispose(); family = null; }
                        }
                    }
                    if (glyphs == null || family == null) return bitmap;
                    float marginX = Math.Max(2f, width * 0.012f);
                    float marginY = Math.Max(2f, height * 0.06f);
                    float scale = Math.Min((width - marginX * 2f) / bounds.Width,
                                           (height - marginY * 2f) / bounds.Height);
                    float drawWidth = bounds.Width * scale, drawHeight = bounds.Height * scale;
                    using (Matrix transform = new Matrix(scale, 0f, 0f, scale,
                        (width - drawWidth) / 2f - bounds.X * scale,
                        (height - drawHeight) / 2f - bounds.Y * scale))
                        glyphs.Transform(transform);
                    RectangleF fitted = glyphs.GetBounds();
                    Color start = dark ? Color.FromArgb(157, 184, 255) : Color.FromArgb(69, 111, 246);
                    Color end = dark ? Color.FromArgb(207, 166, 255) : Color.FromArgb(145, 91, 221);
                    using (LinearGradientBrush fill = new LinearGradientBrush(fitted, start, end, LinearGradientMode.Horizontal))
                    using (Pen outline = new Pen(dark ? Color.FromArgb(54, 245, 245, 255) : Color.FromArgb(210, 255, 255, 255), Math.Max(0.7f, width / 520f))) {
                        outline.LineJoin = LineJoin.Round;
                        g.DrawPath(outline, glyphs);
                        g.FillPath(fill, glyphs);
                    }
                } finally {
                    if (glyphs != null) glyphs.Dispose();
                    if (family != null) family.Dispose();
                }
            }
            return bitmap;
        } catch {
            bitmap.Dispose();
            throw;
        }
    }

    private static GraphicsPath CreateFooterPath(string text, FontFamily family, float emSize) {
        GraphicsPath path = new GraphicsPath();
        if (!string.IsNullOrEmpty(text))
            path.AddString(text, family, (int)FontStyle.Regular, emSize, PointF.Empty, StringFormat.GenericTypographic);
        return path;
    }

    private static string NormalizeStage(string text) {
        string value = (text ?? "").TrimEnd();
        while (value.EndsWith("…", StringComparison.Ordinal) || value.EndsWith("...", StringComparison.Ordinal) || value.EndsWith(".", StringComparison.Ordinal)) {
            if (value.EndsWith("...", StringComparison.Ordinal)) value = value.Substring(0, value.Length - 3).TrimEnd();
            else value = value.Substring(0, value.Length - 1).TrimEnd();
        }
        return value;
    }

    private static bool IsTerminalStage(int percent, string stage) {
        if (percent >= 100) return true;
        string value = (stage ?? "").ToLowerInvariant();
        return value.Contains("失败") || value.Contains("错误") || value.Contains("完成") ||
               value.Contains("failed") || value.Contains("failure") || value.Contains("error") || value.Contains("complete") || value.Contains("done");
    }

    private static Bitmap BuildFooterArtwork(string text, int width, int height, float emSize, bool dark, bool warmPalette, bool reserveDots, out float inkRight) {
        inkRight = 0f;
        if (string.IsNullOrEmpty(text))
            return new Bitmap(width, height, System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
        Bitmap bitmap = new Bitmap(width, height, System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
        try {
            using (Graphics g = Graphics.FromImage(bitmap)) {
                g.Clear(Color.Transparent);
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                string[] candidates = new string[] { "KaiTi", "楷体", "Microsoft YaHei UI" };
                FontFamily family = null;
                GraphicsPath glyphs = null;
                try {
                    foreach (string candidate in candidates) {
                        try {
                            family = new FontFamily(candidate);
                            glyphs = CreateFooterPath(text, family, emSize);
                            if (glyphs.PointCount > 0) break;
                            glyphs.Dispose(); glyphs = null; family.Dispose(); family = null;
                        } catch {
                            if (glyphs != null) { glyphs.Dispose(); glyphs = null; }
                            if (family != null) { family.Dispose(); family = null; }
                        }
                    }
                    if (glyphs == null || family == null) return bitmap;

                    RectangleF measured = glyphs.GetBounds();
                    float dotReserve = reserveDots ? Math.Max(1f, emSize * 1.35f) : 0f;
                    float maxWidth = Math.Max(1f, width - 2f - dotReserve);
                    if (measured.Width > maxWidth) {
                        List<string> elements = new List<string>();
                        System.Globalization.TextElementEnumerator iter = System.Globalization.StringInfo.GetTextElementEnumerator(text);
                        while (iter.MoveNext()) elements.Add(iter.GetTextElement());
                        int low = 0, high = elements.Count;
                        GraphicsPath best = null;
                        while (low <= high) {
                            int count = low + (high - low) / 2;
                            string candidateText = string.Concat(elements.GetRange(0, count).ToArray());
                            if (!reserveDots && count < elements.Count) candidateText += "…";
                            GraphicsPath trial = CreateFooterPath(candidateText, family, emSize);
                            float candidateWidth = trial.GetBounds().Width;
                            if (candidateWidth <= maxWidth) {
                                if (best != null) best.Dispose();
                                best = trial; low = count + 1;
                            } else {
                                trial.Dispose(); high = count - 1;
                            }
                        }
                        glyphs.Dispose();
                        glyphs = best ?? CreateFooterPath("", family, emSize);
                        measured = glyphs.GetBounds();
                    }

                    float marginY = Math.Max(1f, height * 0.04f);
                    float scale = Math.Min(1f, (height - marginY * 2f) / Math.Max(1f, measured.Height));
                    float drawHeight = measured.Height * scale;
                    using (Matrix transform = new Matrix(scale, 0f, 0f, scale,
                        1f - measured.X * scale,
                        (height - drawHeight) / 2f - measured.Y * scale))
                        glyphs.Transform(transform);

                    RectangleF fitted = glyphs.GetBounds();
                    Color start, end;
                    if (warmPalette) {
                        start = dark ? Color.FromArgb(255, 183, 157) : Color.FromArgb(218, 91, 82);
                        end = dark ? Color.FromArgb(255, 205, 184) : Color.FromArgb(196, 73, 127);
                    } else {
                        start = dark ? Color.FromArgb(124, 224, 236) : Color.FromArgb(12, 137, 166);
                        end = dark ? Color.FromArgb(151, 228, 185) : Color.FromArgb(28, 151, 120);
                    }
                    using (LinearGradientBrush fill = new LinearGradientBrush(fitted, start, end, LinearGradientMode.Horizontal))
                    using (Pen outline = new Pen(dark ? Color.FromArgb(54, 245, 245, 255) : Color.FromArgb(175, 255, 255, 255), 0.8f)) {
                        outline.LineJoin = LineJoin.Round;
                        g.DrawPath(outline, glyphs);
                        g.FillPath(fill, glyphs);
                    }
                    inkRight = Math.Max(0f, fitted.Right + 1f);
                } finally {
                    if (glyphs != null) glyphs.Dispose();
                    if (family != null) family.Dispose();
                }
            }
            return bitmap;
        } catch {
            bitmap.Dispose();
            throw;
        }
    }

    private void UpdateTimeArtwork() {
        TimeSpan elapsed = DateTime.Now - _start;
        string text = elapsed.TotalHours >= 1
            ? string.Format("用时  {0}:{1:00}:{2:00}", (int)elapsed.TotalHours, elapsed.Minutes, elapsed.Seconds)
            : string.Format("用时  {0}:{1:00}", (int)elapsed.TotalMinutes, elapsed.Seconds);
        if (text == _lastTimeText) return;
        float ignoredInkRight;
        Bitmap next = BuildFooterArtwork(text, S(230), S(24), S(18), _dark, true, false, out ignoredInkRight);
        Bitmap old = _timeArt;
        _timeArt = next;
        _lastTimeText = text;
        if (old != null) old.Dispose();
        Invalidate(new Rectangle(S(48), S(216), S(240), S(32)));
    }

    private Rectangle GetDotBounds() {
        int diameter = Math.Max(3, S(5));
        float radius = diameter / 2f;
        float spacing = S(7);
        float firstX = S(52) + (int)Math.Ceiling(_stageInkRight) + S(7);
        float lastRight = firstX + spacing * 2f + radius;
        float baseY = S(178) + S(18);
        float maxLift = S(4);
        int padding = Math.Max(2, S(1));
        int left = (int)Math.Floor(firstX - radius) - padding;
        int top = (int)Math.Floor(baseY - maxLift - radius) - padding;
        int right = (int)Math.Ceiling(lastRight) + padding;
        int bottom = (int)Math.Ceiling(baseY + radius) + padding;
        return Rectangle.FromLTRB(left, top, right, bottom);
    }

    private void DrawLoadingDots(Graphics g) {
        if (!_isLoading || _dotBounds.IsEmpty) return;
        int diameter = Math.Max(3, S(5));
        float radius = diameter / 2f;
        float baseY = S(178) + S(18);
        int firstX = S(52) + (int)Math.Ceiling(_stageInkRight) + S(7);
        Color dotColor = _dark ? Color.FromArgb(151, 228, 185) : Color.FromArgb(28, 151, 120);
        using (SolidBrush brush = new SolidBrush(dotColor)) {
            for (int i = 0; i < 3; i++) {
                double phase = _dotPhase - i * Math.PI * 0.72;
                float lift = (float)Math.Max(0.0, Math.Sin(phase)) * S(4);
                float x = firstX + i * S(7) - radius;
                float y = baseY - lift - radius;
                g.FillEllipse(brush, x, y, diameter, diameter);
            }
        }
    }

    private int MascotRightAt(int physicalY) {
        if (_mascot == null) return S(468);
        int top = S(4), left = S(435);
        int row = physicalY - top;
        if (row < 0 || row >= _mascot.Height) return -1;
        for (int x = _mascot.Width - 1; x >= 0; x--) {
            if (_mascot.GetPixel(x, row).A >= 12) return left + x;
        }
        return -1;
    }

    private GraphicsPath CardPath() {
        int left = S(24), top = S(60), bottom = S(340), radius = S(18);
        int d = Math.Max(2, radius * 2);
        List<Point> edge = new List<Point>();
        int previous = S(470);
        int step = Math.Max(1, S(1));
        for (int y = top; y <= bottom; y += step) {
            int right = MascotRightAt(y);
            if (right >= 0) previous = right + Math.Max(1, S(1));
            edge.Add(new Point(Math.Min(ClientSize.Width - 1, previous), y));
        }
        if (edge.Count == 0 || edge[edge.Count - 1].Y != bottom)
            edge.Add(new Point(Math.Min(ClientSize.Width - 1, previous), bottom));

        GraphicsPath path = new GraphicsPath();
        path.StartFigure();
        path.AddLine(left + radius, top, edge[0].X, top);
        if (edge.Count > 1) path.AddLines(edge.ToArray());
        path.AddLine(edge[edge.Count - 1].X, bottom, left + radius, bottom);
        path.AddArc(left, bottom - d, d, d, 90, 90);
        path.AddLine(left, bottom - radius, left, top + radius);
        path.AddArc(left, top, d, d, 180, 90);
        path.CloseFigure();
        return path;
    }

    private GraphicsPath MascotRegionPath() {
        GraphicsPath path = new GraphicsPath();
        if (_mascot == null) return path;
        int left = S(435), top = S(4), cardTop = S(60);
        int rowsAboveCard = Math.Min(_mascot.Height, cardTop - top);
        // The card contains the entire mascot below its top edge; only add
        // pixels above it so the head can overhang without a rectangular HWND.
        for (int y = 0; y < rowsAboveCard; y++) {
            int x = 0;
            while (x < _mascot.Width) {
                while (x < _mascot.Width && _mascot.GetPixel(x, y).A < 12) x++;
                int start = x;
                while (x < _mascot.Width && _mascot.GetPixel(x, y).A >= 12) x++;
                if (x > start) path.AddRectangle(new Rectangle(left + start, top + y, x - start, 1));
            }
        }
        return path;
    }

    private void UpdateWindowRegion() {
        if (_updatingRegion || !IsHandleCreated || IsDisposed || ClientSize.Width < 2 || ClientSize.Height < 2) return;
        if (_regionSize == ClientSize && Region != null) return;
        _updatingRegion = true;
        try {
            using (GraphicsPath card = CardPath())
            using (GraphicsPath figure = MascotRegionPath()) {
                Region combined = new Region(card);
                if (figure.PointCount > 0) combined.Union(figure);
                using (Region clientBounds = new Region(new Rectangle(Point.Empty, ClientSize)))
                    combined.Intersect(clientBounds);
                // Control.Region owns the assigned object and releases its predecessor.
                Region = combined;
            }
            _regionSize = ClientSize;
        } finally {
            _updatingRegion = false;
        }
    }

    private Bitmap BuildBackground(int width, int height) {
        Bitmap b = new Bitmap(width, height, System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
        using (Graphics g = Graphics.FromImage(b)) {
            g.Clear(Color.Transparent);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            Rectangle bounds = new Rectangle(0, 0, width, height);
            using (GraphicsPath card = CardPath())
            using (LinearGradientBrush fill = new LinearGradientBrush(bounds, _bg, _bgEnd, LinearGradientMode.Vertical))
                g.FillPath(fill, card);
        }
        return b;
    }

    private void RebuildBackground() {
        Bitmap next = BuildBackground(ClientSize.Width, ClientSize.Height);
        Bitmap old = _background;
        _background = next;
        if (old != null) old.Dispose();
    }

    protected override CreateParams CreateParams {
        get { CreateParams cp = base.CreateParams; cp.ExStyle |= 0x80; return cp; }
    }

    protected override void OnHandleCreated(EventArgs e) {
        base.OnHandleCreated(e);
        try {
            _regionSize = Size.Empty;
            UpdateWindowRegion();
            int policy = 2; DwmSetWindowAttribute(Handle, 2, ref policy, 4);
        } catch { }
    }

    protected override void OnSizeChanged(EventArgs e) {
        base.OnSizeChanged(e);
        if (_updatingRegion || !IsHandleCreated || IsDisposed) return;
        try {
            RebuildBackground();
            _regionSize = Size.Empty;
            UpdateWindowRegion();
            Invalidate();
        } catch { }
    }

    protected override void OnLoad(EventArgs e) {
        base.OnLoad(e);
        Rectangle wa = Screen.FromPoint(Cursor.Position).WorkingArea;
        Location = new Point(wa.X + (wa.Width - Width) / 2, wa.Y + (wa.Height - Height) / 2);
    }

    private static GraphicsPath Pill(RectangleF r) {
        GraphicsPath p = new GraphicsPath();
        float d = r.Height;
        p.AddArc(r.X, r.Y, d, d, 90, 180);
        p.AddArc(r.Right-d, r.Y, d, d, 270, 180);
        p.CloseFigure();
        return p;
    }

    public void SetProgress(int percent, string stage) {
        _shown = Math.Max(0, Math.Min(100, percent));
        string normalized = NormalizeStage(stage);
        bool loading = !IsTerminalStage(_shown, normalized);
        bool changed = stage != Stage;
        bool loadingChanged = loading != _isLoading;
        Rectangle previousDots = _dotBounds;
        _isLoading = loading;
        if (changed || loadingChanged) {
            if (changed) Stage = stage;
            Bitmap next = BuildFooterArtwork(normalized, S(430), S(36), S(24), _dark, false, _isLoading, out _stageInkRight);
            Bitmap old = _stageArt;
            _stageArt = next;
            if (old != null) old.Dispose();
            _dotBounds = GetDotBounds();
        }
        if (loadingChanged) {
            if (_isLoading) _dotPhase = 0f;
            Invalidate(previousDots);
            Invalidate(_dotBounds);
        }
        if (changed) {
            Invalidate(new Rectangle(S(48), S(172), S(450), S(52)));
        }
        Invalidate(new Rectangle(S(48), S(292), S(430), S(18)));
    }

    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
        if (_background != null) g.DrawImageUnscaled(_background, 0, 0);
        else g.Clear(_bg);

        if (_logo != null) g.DrawImageUnscaled(_logo, S(50), S(101));
        if (_wordmark != null) g.DrawImageUnscaled(_wordmark, S(106), S(98));
        if (_stageArt != null) g.DrawImageUnscaled(_stageArt, S(52), S(178));
        DrawLoadingDots(g);
        if (_timeArt != null) g.DrawImageUnscaled(_timeArt, S(52), S(220));

        RectangleF track = new RectangleF(S(52), S(296), S(420), S(10));
        using (GraphicsPath tp = Pill(track))
        using (SolidBrush tb = new SolidBrush(_track)) g.FillPath(tb, tp);
        float w = track.Width * _shown / 100f;
        if (w > 0.5f) {
            RectangleF fill = new RectangleF(track.X, track.Y, Math.Max(w, track.Height), track.Height);
            using (GraphicsPath fp = Pill(fill))
            using (LinearGradientBrush accent = new LinearGradientBrush(track, Accent1, Accent2, LinearGradientMode.Horizontal))
                g.FillPath(accent, fp);
        }
        if (_mascot != null) g.DrawImageUnscaled(_mascot, S(435), S(4));
    }

    protected override void OnFormClosed(FormClosedEventArgs e) {
        if (_tick != null) _tick.Stop();
        base.OnFormClosed(e);
    }

    protected override void Dispose(bool disposing) {
        if (disposing) {
            if (_tick != null) { _tick.Stop(); _tick.Dispose(); }
            if (_logo != null) _logo.Dispose();
            if (_mascot != null) _mascot.Dispose();
            if (_background != null) _background.Dispose();
            if (_wordmark != null) _wordmark.Dispose();
            if (_stageArt != null) _stageArt.Dispose();
            if (_timeArt != null) _timeArt.Dispose();
        }
        base.Dispose(disposing);
    }
}

public static class DshProgress {
    [DllImport("user32.dll")] private static extern bool SetProcessDPIAware();
    private static DshProgressForm _form;
    private static Thread _thread;
    private static readonly object _lock = new object();
    private static readonly ManualResetEvent _ready = new ManualResetEvent(false);

    public static bool Show(string title, string stage, string logoPath) {
        string mascotPath = Path.Combine(Path.GetDirectoryName(logoPath) ?? "", "whale-maid-static.png");
        return Show(title, stage, logoPath, mascotPath, true);
    }
    public static bool Show(string title, string stage, string logoPath, bool staticMascot) {
        string mascotPath = Path.Combine(Path.GetDirectoryName(logoPath) ?? "", "whale-maid-static.png");
        return Show(title, stage, logoPath, mascotPath, true);
    }
    public static bool Show(string title, string stage, string logoPath, string mascotPath, bool staticMascot) {
        lock (_lock) {
            if (_thread != null && _thread.IsAlive) return _form != null;
            _thread = null; _form = null; _ready.Reset();
            _thread = new Thread(delegate() {
                try { SetProcessDPIAware(); } catch { }
                Application.EnableVisualStyles();
                DshProgressForm f = new DshProgressForm(title, stage, logoPath, mascotPath);
                IntPtr handle = f.Handle;
                _form = f; _ready.Set(); Application.Run(f);
            });
            _thread.SetApartmentState(ApartmentState.STA);
            _thread.IsBackground = true;
            _thread.Start();
        }
        return _ready.WaitOne(5000);
    }
    public static void SetStage(int percent, string stage) {
        DshProgressForm f;
        lock (_lock) { f = _form; }
        if (f == null || f.IsDisposed) return;
        int p = Math.Max(0, Math.Min(100, percent));
        try { f.BeginInvoke((MethodInvoker)delegate() { f.SetProgress(p, stage); }); }
        catch (InvalidOperationException) { }
    }
    public static void Close() {
        DshProgressForm f; Thread t;
        lock (_lock) { f = _form; t = _thread; _form = null; }
        if (f != null && !f.IsDisposed) {
            try { f.BeginInvoke((MethodInvoker)delegate() { f.Close(); }); }
            catch (InvalidOperationException) { }
        }
        if (t != null && t != Thread.CurrentThread && t.Join(3000))
            lock (_lock) { if (_thread == t) { _thread = null; _form = null; } }
    }
}
"@ -ReferencedAssemblies @('System.Windows.Forms.dll','System.Drawing.dll')

function Show-ProgressWindow {
    param([string]$Stage)
    # Fail loudly if the window cannot appear. Both real startup and preview use
    # the edited standing mascot; the legacy -StaticMascot switch is accepted.
    $logo = Join-Path $PSScriptRoot 'deepseek-logo.png'
    $mascot = Join-Path $PSScriptRoot 'whale-maid-static.png'
    if (-not [DshProgress]::Show('DeepSeek Harness', $Stage, $logo, $mascot, $true)) {
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

    if ($Preview) {
        $previewMs = [Math]::Max(1000, $PreviewSeconds * 1000)
        $previewStages = @(@(10, '正在检查本地启动配置…'), @(38, '正在准备 DeepSeek Harness…'), @(68, '正在等待服务就绪…'), @(91, '正在打开浏览器…'))
        $each = [Math]::Max(1, [int]($previewMs / $previewStages.Count))
        foreach ($item in $previewStages) {
            [DshProgress]::SetStage($item[0], $item[1])
            Start-Sleep -Milliseconds $each
        }
        [DshProgress]::SetStage(100, '预览完成')
        Start-Sleep -Milliseconds 500
        [DshProgress]::Close()
        exit 0
    }

    if (-not (Test-Path -LiteralPath $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }

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
        # The window runs its own elapsed clock and loading-dot animation, so it reads as
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
