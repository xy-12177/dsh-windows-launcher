param(
    [ValidateSet('Compile','Capture','PreviewIsolation','StaticSample','Flows','Fallback')]
    [string]$Mode = 'Compile',
    [string]$SourcePath = (Join-Path $PSScriptRoot '..\launcher\start-dsh.ps1'),
    [string]$OutputDir = (Join-Path $PSScriptRoot '..\images'),
    [int]$DurationSeconds = 30
)

$ErrorActionPreference = 'Stop'
$source = Get-Content -LiteralPath $SourcePath -Raw
$match = [regex]::Match($source, '(?s)Add-Type\s+-TypeDefinition\s+@"\s*(.*?)\s*"@\s+-ReferencedAssemblies')
if (-not $match.Success) { throw 'Could not locate the embedded DshProgress C# source.' }
$cs = $match.Groups[1].Value

# Theme and DPI test hooks exist only in this in-memory build.
$cs = $cs.Replace('public class DshProgressForm : Form {', 'public static class DshValidation { public static bool Dark; public static float Scale; public static DateTime Start = DateTime.Now; public static DateTime Now { get { return DateTime.Now; } } }' + [Environment]::NewLine + '    public class DshProgressForm : Form {')
$cs = [regex]::Replace($cs, '(?s)bool dark = false;\s*try \{\s*object v = Microsoft\.Win32\.Registry\.GetValue\(.*?\}\s*catch \{ \}', 'bool dark = DshValidation.Dark;', 1)
$cs = $cs.Replace('using (Graphics g = Graphics.FromHwnd(IntPtr.Zero)) { _k = g.DpiX / 96f; }', 'using (Graphics g = Graphics.FromHwnd(IntPtr.Zero)) { _k = DshValidation.Scale > 0 ? DshValidation.Scale : g.DpiX / 96f; }')
$cs = $cs.Replace('private readonly DateTime _start = DateTime.Now;', 'private readonly DateTime _start = DshValidation.Start;')
$cs = $cs.Replace('DateTime.Now - _start', 'DshValidation.Now - _start')

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition $cs -ReferencedAssemblies @('System.Windows.Forms.dll','System.Drawing.dll')
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class DshWindowProbe {
    private delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] private static extern int GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    public static bool HasVisibleWindow(int target) {
        bool found = false;
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            uint pid; GetWindowThreadProcessId(h, out pid);
            if (pid == (uint)target && IsWindowVisible(h) && GetWindowTextLength(h) > 0) { found = true; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
"@

if ($Mode -eq 'Compile') {
    if (-not ('DshProgress' -as [type])) { throw 'Embedded C# type did not compile.' }
    Write-Output 'PASS: embedded C# compiled in Windows PowerShell.'
}

$preview = [regex]::Match($source, '(?s)if \(\$Preview\) \{(.*?)\n\s*if \(-not \(Test-Path -LiteralPath \$WorkDir\)\)')
if (-not $preview.Success -or $preview.Groups[1].Value -match 'New-Item|Start-Process|Test-PortListening|Open-Ui') { throw 'Preview branch must return before workspace creation and service/browser operations.' }
if ($preview.Groups[1].Value -notmatch '\[DshProgress\]::Close\(\)\s*exit 0') { throw 'Preview branch does not close and exit cleanly.' }
Write-Output 'PASS: preview source branch returns before workspace/.run setup and service/browser operations.'
$show = [regex]::Match($source,'(?s)function Show-ProgressWindow \{(.*?)(?=\n\})')
if (-not $show.Success -or $show.Groups[1].Value -notmatch '\[DshProgress\]::Show\([^\r\n]*\$mascot,\s*\$true\)') { throw 'Normal and preview launch must both select the static portrait.' }
if ($cs -match 'whale-maid-run-\d') { throw 'Legacy running frames are still referenced by the active C# UI.' }
Write-Output 'PASS: active launch and preview paths select the static portrait; legacy running frames are not loaded.'

if ($Mode -eq 'Capture') {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    $assetDir = Split-Path -Parent $SourcePath
    $mascot = Join-Path $assetDir 'whale-maid-static.png'
    $logo = Join-Path $assetDir 'deepseek-logo.png'
    if (-not (Test-Path -LiteralPath $mascot)) { throw 'No static mascot image found next to launcher.' }
    if ($cs -notmatch 'KaiTi.*楷体.*Microsoft YaHei UI') { throw 'Footer vector art must retain the KaiTi/Kaiti CJK fallback chain.' }
    $kaiti = [Drawing.FontFamily]::new('KaiTi')
    try { if ($kaiti.Name -notin @('KaiTi','楷体')) { throw "KaiTi resolved to unexpected family '$($kaiti.Name)'." } }
    finally { $kaiti.Dispose() }
    Write-Output 'PASS: Windows KaiTi family is installed and resolves for Chinese footer glyphs.'
    foreach ($dark in @($false,$true)) {
        foreach ($scale in @(1.0,1.5,2.0)) {
            [DshValidation]::Dark = $dark
            [DshValidation]::Scale = $scale
            $form = [DshProgressForm]::new('DeepSeek Harness','正在启动…',$logo,$mascot)
            try {
                $actualScale = $form.GetType().GetField('_k',[Reflection.BindingFlags]'Instance,NonPublic').GetValue($form)
                if ([Math]::Abs($actualScale-$scale) -gt 0.01) { throw "DPI injection failed: requested $scale, got $actualScale." }
                if ($form.ClientSize.Width -ne [int](760*$scale) -or $form.ClientSize.Height -ne [int](360*$scale)) { throw "DPI-scaled client size mismatch: $($form.ClientSize.Width)x$($form.ClientSize.Height)." }
                $form.SetProgress(68,'正在等待服务就绪…')
                if ($form.Stage -ne '正在等待服务就绪…') { throw 'SetProgress did not update the stage text.' }
                if ($null -eq $form.GetType().GetField('_stageArt',[Reflection.BindingFlags]'Instance,NonPublic').GetValue($form)) { throw 'SetProgress did not produce cached stage artwork.' }
                $form.CreateControl()
                $bmp = [Drawing.Bitmap]::new($form.ClientSize.Width,$form.ClientSize.Height)
                try {
                    $form.DrawToBitmap($bmp,[Drawing.Rectangle]::new(0,0,$bmp.Width,$bmp.Height))
                    $theme = 'light'; if ($dark) { $theme = 'dark' }
                    $name = "validation-$theme-$([int]($scale*100)).png"
                    $path = Join-Path $OutputDir $name
                    $bmp.SetResolution(96*$scale,96*$scale)
                    $bmp.Save($path,[Drawing.Imaging.ImageFormat]::Png)
                    Write-Output "CAPTURE: $path ($($bmp.Width)x$($bmp.Height))"
                } finally { $bmp.Dispose() }
            } finally { $form.Close(); $form.Dispose() }
        }
    }
    [DshValidation]::Dark = $false; [DshValidation]::Scale = 1.0
    $stressText = '正在检查本地配置并准备 DeepSeek Harness 服务环境，随后等待服务启动就绪…'
    $stress = [DshProgressForm]::new('DeepSeek Harness','正在启动…',$logo,$mascot)
    try {
        $stress.SetProgress(68,$stressText)
        $stress.CreateControl()
        $bmp = [Drawing.Bitmap]::new($stress.ClientSize.Width,$stress.ClientSize.Height)
        try {
            $stress.DrawToBitmap($bmp,[Drawing.Rectangle]::new(0,0,$bmp.Width,$bmp.Height))
            $stressPath = Join-Path $OutputDir 'validation-stage-stress.png'
            $bmp.Save($stressPath,[Drawing.Imaging.ImageFormat]::Png)
            Write-Output "CAPTURE: $stressPath ($($bmp.Width)x$($bmp.Height))"
        } finally { $bmp.Dispose() }
    } finally { $stress.Close(); $stress.Dispose() }
    $clockCases = @(@{Name='1s';AgeSeconds=1;Expected='0:01'},@{Name='10m';AgeSeconds=600;Expected='10:00'},@{Name='100m';AgeSeconds=6000;Expected='1:40:00'})
    foreach ($clockCase in $clockCases) {
        [DshValidation]::Dark = $false; [DshValidation]::Scale = 1.0
        [DshValidation]::Start = [DateTime]::Now.AddSeconds(-$clockCase.AgeSeconds)
        $clockForm = [DshProgressForm]::new('DeepSeek Harness','正在启动…',$logo,$mascot)
        try {
            $clockForm.SetProgress(68,'正在等待服务就绪…')
            $timeText = [string]$clockForm.GetType().GetField('_lastTimeText',[Reflection.BindingFlags]'Instance,NonPublic').GetValue($clockForm)
            if ($timeText -notlike "*$($clockCase.Expected)*") { throw "Clock cache for $($clockCase.Name) was '$timeText'." }
            $timeBitmap = $clockForm.GetType().GetField('_timeArt',[Reflection.BindingFlags]'Instance,NonPublic').GetValue($clockForm)
            if ($null -eq $timeBitmap) { throw "Clock bitmap for $($clockCase.Name) was empty." }
            $clockForm.CreateControl()
            $bmp = [Drawing.Bitmap]::new($clockForm.ClientSize.Width,$clockForm.ClientSize.Height)
            try {
                $clockForm.DrawToBitmap($bmp,[Drawing.Rectangle]::new(0,0,$bmp.Width,$bmp.Height))
                $clockPath = Join-Path $OutputDir "validation-clock-$($clockCase.Name).png"
                $bmp.Save($clockPath,[Drawing.Imaging.ImageFormat]::Png)
                Write-Output "CLOCK: $clockPath text='$timeText'"
            } finally { $bmp.Dispose() }
        } finally { $clockForm.Close(); $clockForm.Dispose() }
    }
    Write-Output 'NOTE: theme and device scale are injected in memory; cached vector wordmark/footer artwork is not font-scaled a second time, and Windows settings remain unchanged.'
}

if ($Mode -eq 'PreviewIsolation') {
    $target = Join-Path $OutputDir ('validation-no-write-' + [guid]::NewGuid().ToString('N'))
    $runDir = Join-Path (Split-Path -Parent $SourcePath) '.run'
    $before = @()
    if (Test-Path -LiteralPath $runDir) { $before = @(Get-ChildItem -LiteralPath $runDir -File | ForEach-Object { "$($_.Name)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" } | Sort-Object) }
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $args = "-NoProfile -ExecutionPolicy Bypass -File `"$SourcePath`" -Preview -PreviewSeconds 1 -WorkDir `"$target`""
    $child = Start-Process -FilePath $psExe -ArgumentList $args -WindowStyle Hidden -PassThru
    $child.WaitForExit()
    if ($child.ExitCode -ne 0) { throw "Preview exited with code $($child.ExitCode)." }
    if (Test-Path -LiteralPath $target) { throw 'Preview created the supplied WorkDir.' }
    $after = @()
    if (Test-Path -LiteralPath $runDir) { $after = @(Get-ChildItem -LiteralPath $runDir -File | ForEach-Object { "$($_.Name)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" } | Sort-Object) }
    if (Compare-Object -ReferenceObject $before -DifferenceObject $after) { throw 'Preview changed files in launcher/.run.' }
    Write-Output 'PASS: real preview exited successfully without creating WorkDir or changing launcher/.run.'
}

if ($Mode -eq 'StaticSample') {
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $args = "-NoProfile -ExecutionPolicy Bypass -File `"$SourcePath`" -Preview -StaticMascot -PreviewSeconds $DurationSeconds"
    $child = Start-Process -FilePath $psExe -ArgumentList $args -WindowStyle Hidden -PassThru
    $proc = $child
    $ready = [Diagnostics.Stopwatch]::StartNew()
    while (-not $proc.HasExited -and -not [DshWindowProbe]::HasVisibleWindow($proc.Id) -and $ready.Elapsed.TotalSeconds -lt 20) {
        Start-Sleep -Milliseconds 100; $proc.Refresh()
    }
    if ($proc.HasExited -or -not [DshWindowProbe]::HasVisibleWindow($proc.Id)) { throw 'Static preview window did not appear.' }
    $cpu0 = $proc.TotalProcessorTime.TotalMilliseconds
    $wall = [Diagnostics.Stopwatch]::StartNew()
    $maxWs = 0L; $maxPrivate = 0L
    while (-not $proc.HasExited) {
        $proc.Refresh()
        if ($proc.WorkingSet64 -gt $maxWs) { $maxWs = $proc.WorkingSet64 }
        if ($proc.PrivateMemorySize64 -gt $maxPrivate) { $maxPrivate = $proc.PrivateMemorySize64 }
        Start-Sleep -Milliseconds 200
    }
    $proc.WaitForExit(); $wall.Stop(); $proc.Refresh()
    if ($proc.ExitCode -ne 0) { throw "Static preview exited with code $($proc.ExitCode)." }
    $cpuPct = (($proc.TotalProcessorTime.TotalMilliseconds-$cpu0) / [Math]::Max(1,$wall.Elapsed.TotalMilliseconds)) * 100
    $row = [pscustomobject]@{Mode='static';Seconds=[Math]::Round($wall.Elapsed.TotalSeconds,2);CpuOneCorePct=[Math]::Round($cpuPct,2);WorkingSetPeakMiB=[Math]::Round($maxWs/1MB,2);PrivateBytesPeakMiB=[Math]::Round($maxPrivate/1MB,2)}
    $csv = Join-Path $OutputDir 'performance-static-current-ui.csv'
    $row | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
    $row | Format-List
    Write-Output "PASS: one real static preview sample; $csv"
}

if ($Mode -eq 'Flows') {
    & (Join-Path $PSScriptRoot 'Simulate-LauncherFlows.ps1') -SourcePath $SourcePath
    if ($LASTEXITCODE -ne 0) { throw 'Launcher flow simulations failed.' }
}

if ($Mode -eq 'Fallback') {
    $assetDir = Split-Path -Parent $SourcePath
    $logo = Join-Path $assetDir 'deepseek-logo.png'
    $mascot = Join-Path $assetDir 'whale-maid-static.png'
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('dsh-fallback-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temp | Out-Null
    try {
        Copy-Item -LiteralPath $logo -Destination (Join-Path $temp 'deepseek-logo.png')
        $bad = Join-Path $temp 'corrupt.png'
        [IO.File]::WriteAllBytes($bad,[byte[]](1,2,3,4,5,6))
        foreach ($case in @(@{Name='missing';Path=(Join-Path $temp 'missing.png')},@{Name='corrupt';Path=$bad})) {
            $form = [DshProgressForm]::new('DeepSeek Harness','正在等待服务就绪…',$logo,$case.Path)
            try {
                $loaded = $form.GetType().GetField('_mascot',[Reflection.BindingFlags]'Instance,NonPublic').GetValue($form)
                if ($null -eq $loaded) { throw "$($case.Name) mascot did not fall back to the adjacent logo." }
                $form.CreateControl()
                $bitmap = [Drawing.Bitmap]::new($form.ClientSize.Width,$form.ClientSize.Height)
                try { $form.DrawToBitmap($bitmap,[Drawing.Rectangle]::new(0,0,$bitmap.Width,$bitmap.Height)) }
                finally { $bitmap.Dispose() }
            } finally { $form.Close(); $form.Dispose() }
            Write-Output "PASS: $($case.Name) mascot fallback renders and closes."
        }
    } finally {
        $full = [IO.Path]::GetFullPath($temp); $root = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not $full.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing to remove fallback temp outside TEMP.' }
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}
