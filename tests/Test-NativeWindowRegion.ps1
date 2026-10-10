param(
    [string]$SourcePath = (Join-Path $PSScriptRoot '..\launcher\start-dsh.ps1'),
    [string]$OutputDir = (Join-Path $PSScriptRoot '..\images'),
    [string]$Label = 'current',
    [int]$PreviewSeconds = 8,
    [switch]$RequireMatch
)

$ErrorActionPreference = 'Stop'
$source = Get-Content -LiteralPath $SourcePath -Raw
$match = [regex]::Match($source, '(?s)Add-Type\s+-TypeDefinition\s+@"\s*(.*?)\s*"@\s+-ReferencedAssemblies')
if (-not $match.Success) { throw 'Could not locate the production embedded C# source.' }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition $match.Groups[1].Value -ReferencedAssemblies @('System.Windows.Forms.dll','System.Drawing.dll')
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class DshNativeRegionProbe {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll", SetLastError=true)] public static extern int GetWindowRgnBox(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool GetClientRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
    private delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern int GetWindowTextLength(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
    public static IntPtr FindVisibleWindow(int targetPid) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr hwnd, IntPtr lParam) {
            uint pid; GetWindowThreadProcessId(hwnd, out pid);
            if (pid == (uint)targetPid && IsWindowVisible(hwnd) && GetWindowTextLength(hwnd) > 0) { found = hwnd; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
    public static void ResizeClient(System.Windows.Forms.Form form, int width, int height) {
        form.Invoke((System.Windows.Forms.MethodInvoker)delegate { form.ClientSize = new System.Drawing.Size(width, height); });
    }
}
"@ -ReferencedAssemblies @('System.Windows.Forms.dll','System.Drawing.dll')

$assetDir = Split-Path -Parent $SourcePath
$logo = Join-Path $assetDir 'deepseek-logo.png'
$mascot = Join-Path $assetDir 'whale-maid-static.png'
if (-not [DshProgress]::Show('DeepSeek Harness','正在等待服务就绪…',$logo,$mascot,$true)) { throw 'Production progress window failed to show.' }
try {
    $field = [DshProgress].GetField('_form',[Reflection.BindingFlags]'Static,NonPublic')
    $form = $field.GetValue($null)
    if ($null -eq $form -or -not $form.IsHandleCreated) { throw 'Production form handle is missing.' }
    function Read-Bounds([string]$sample) {
        $nativeRegion = New-Object DshNativeRegionProbe+RECT
        $clientRect = New-Object DshNativeRegionProbe+RECT
        $windowRect = New-Object DshNativeRegionProbe+RECT
        $regionType = [DshNativeRegionProbe]::GetWindowRgnBox($form.Handle,[ref]$nativeRegion)
        [void][DshNativeRegionProbe]::GetClientRect($form.Handle,[ref]$clientRect)
        [void][DshNativeRegionProbe]::GetWindowRect($form.Handle,[ref]$windowRect)
        $graphics = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
        try { $managedBounds = $form.Region.GetBounds($graphics) } finally { $graphics.Dispose() }
        $clientW = $clientRect.Right - $clientRect.Left
        $clientH = $clientRect.Bottom - $clientRect.Top
        $regionW = $nativeRegion.Right - $nativeRegion.Left
        $regionH = $nativeRegion.Bottom - $nativeRegion.Top
        $result = [pscustomobject]@{
            Label=$Label; Sample=$sample; Handle=('0x{0:X}' -f $form.Handle.ToInt64())
            ClientSize="$($form.ClientSize.Width)x$($form.ClientSize.Height)"; FormSize="$($form.Width)x$($form.Height)"
            ManagedRegionBounds=('{0},{1}..{2},{3}' -f $managedBounds.Left,$managedBounds.Top,$managedBounds.Right,$managedBounds.Bottom)
            NativeRegionType=$regionType; NativeRegionBounds=('{0},{1}..{2},{3}' -f $nativeRegion.Left,$nativeRegion.Top,$nativeRegion.Right,$nativeRegion.Bottom)
            NativeClientBounds=('{0},{1}..{2},{3}' -f $clientRect.Left,$clientRect.Top,$clientRect.Right,$clientRect.Bottom)
            NativeWindowBounds=('{0},{1}..{2},{3}' -f $windowRect.Left,$windowRect.Top,$windowRect.Right,$windowRect.Bottom)
            RegionMatchesClient=($regionType -ne 0 -and $regionW -ge ($clientW-2) -and $regionH -ge ($clientH-2))
        }
        $result | Format-List | Out-Host
        return $result
    }
    $initial = Read-Bounds 'initial'
    $original = $form.ClientSize
    [DshNativeRegionProbe]::ResizeClient($form,800,400)
    $resized = Read-Bounds 'resized-800x400'
    [DshNativeRegionProbe]::ResizeClient($form,$original.Width,$original.Height)
    $restored = Read-Bounds 'restored'
    if ($RequireMatch -and (-not $initial.RegionMatchesClient -or -not $resized.RegionMatchesClient -or -not $restored.RegionMatchesClient)) {
        throw 'Managed production form native region does not match the client at initial, resized, and restored sizes.'
    }
} finally {
    [DshProgress]::Close()
}

# Probe the real Preview child process, finding its visible HWND by PID rather than inferring visibility from exit code.
$workDir = Join-Path ([IO.Path]::GetTempPath()) ('dsh-preview-region-' + [guid]::NewGuid().ToString('N'))
$runDir = Join-Path $assetDir '.run'
$beforeRun = @()
if (Test-Path -LiteralPath $runDir) { $beforeRun = @(Get-ChildItem -LiteralPath $runDir -File | ForEach-Object { "$($_.Name)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" } | Sort-Object) }
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$args = "-NoProfile -ExecutionPolicy Bypass -File `"$SourcePath`" -Preview -PreviewSeconds $PreviewSeconds -WorkDir `"$workDir`""
$preview = Start-Process -FilePath $psExe -ArgumentList $args -WindowStyle Hidden -PassThru
try {
    $hwnd = [IntPtr]::Zero
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while (-not $preview.HasExited -and $watch.Elapsed.TotalSeconds -lt 15 -and $hwnd -eq [IntPtr]::Zero) {
        $preview.Refresh()
        $hwnd = [DshNativeRegionProbe]::FindVisibleWindow($preview.Id)
        if ($hwnd -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 100 }
    }
    if ($hwnd -eq [IntPtr]::Zero) { throw 'Could not find a visible window owned by the real Preview process.' }
    $nativeRegion = New-Object DshNativeRegionProbe+RECT
    $clientRect = New-Object DshNativeRegionProbe+RECT
    $windowRect = New-Object DshNativeRegionProbe+RECT
    $regionType = [DshNativeRegionProbe]::GetWindowRgnBox($hwnd,[ref]$nativeRegion)
    [void][DshNativeRegionProbe]::GetClientRect($hwnd,[ref]$clientRect)
    [void][DshNativeRegionProbe]::GetWindowRect($hwnd,[ref]$windowRect)
    $clientW=$clientRect.Right-$clientRect.Left; $clientH=$clientRect.Bottom-$clientRect.Top
    $regionW=$nativeRegion.Right-$nativeRegion.Left; $regionH=$nativeRegion.Bottom-$nativeRegion.Top
    $matches=$regionType -ne 0 -and $regionW -ge ($clientW-2) -and $regionH -ge ($clientH-2)
    [pscustomobject]@{
        Label=$Label; Sample='actual-preview-process'; ProcessId=$preview.Id; Handle=('0x{0:X}' -f $hwnd.ToInt64())
        NativeClientBounds=('{0},{1}..{2},{3}' -f $clientRect.Left,$clientRect.Top,$clientRect.Right,$clientRect.Bottom)
        NativeRegionType=$regionType; NativeRegionBounds=('{0},{1}..{2},{3}' -f $nativeRegion.Left,$nativeRegion.Top,$nativeRegion.Right,$nativeRegion.Bottom)
        NativeWindowBounds=('{0},{1}..{2},{3}' -f $windowRect.Left,$windowRect.Top,$windowRect.Right,$windowRect.Bottom)
        RegionMatchesClient=$matches
    } | Format-List | Out-Host
    $width=$windowRect.Right-$windowRect.Left; $height=$windowRect.Bottom-$windowRect.Top
    $bitmap=New-Object Drawing.Bitmap($width,$height)
    try {
        $graphics=[Drawing.Graphics]::FromImage($bitmap)
        try {
            $hdc=$graphics.GetHdc()
            try { $printOk=[DshNativeRegionProbe]::PrintWindow($hwnd,$hdc,2) }
            finally { $graphics.ReleaseHdc($hdc) }
        } finally { $graphics.Dispose() }
        if($printOk){$bitmap.Save((Join-Path $OutputDir 'validation-native-preview.png'),[Drawing.Imaging.ImageFormat]::Png); Write-Output "Target-window PrintWindow capture: $(Join-Path $OutputDir 'validation-native-preview.png')"}
        else {Write-Output 'PrintWindow did not render the target window.'}
    } finally {$bitmap.Dispose()}
    $preview.WaitForExit(); $preview.Refresh()
    if($preview.ExitCode -ne 0){throw "Real Preview exited with code $($preview.ExitCode)."}
    if(Test-Path -LiteralPath $workDir){throw 'Real Preview created the supplied WorkDir.'}
    $afterRun=@()
    if(Test-Path -LiteralPath $runDir){$afterRun=@(Get-ChildItem -LiteralPath $runDir -File | ForEach-Object { "$($_.Name)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" } | Sort-Object)}
    if(Compare-Object -ReferenceObject $beforeRun -DifferenceObject $afterRun){throw 'Real Preview changed launcher/.run files.'}
    if($RequireMatch -and -not $matches){throw 'Real Preview native region does not match its client bounds.'}
    Write-Output "PASS: actual Preview ExitCode=$($preview.ExitCode); WorkDir absent; launcher/.run unchanged."
} finally {
    if(-not $preview.HasExited){Stop-Process -Id $preview.Id -Force}
}
