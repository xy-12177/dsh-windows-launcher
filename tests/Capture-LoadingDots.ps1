param(
    [string]$SourcePath = (Join-Path $PSScriptRoot '..\launcher\start-dsh.ps1'),
    [string]$OutputDir = (Join-Path $PSScriptRoot '.artifacts'),
    [int]$FrameCount = 12,
    [int]$IntervalMs = 100,
    [int]$PreviewSeconds = 16
)
$ErrorActionPreference = 'Stop'
if ($FrameCount -lt 8 -or $FrameCount -gt 15) { throw 'FrameCount must be between 8 and 15.' }
if ($IntervalMs -lt 80 -or $IntervalMs -gt 200) { throw 'IntervalMs must be 80..200.' }
$source = Get-Content -LiteralPath $SourcePath -Raw
$match = [regex]::Match($source, '(?s)Add-Type\s+-TypeDefinition\s+@"\s*(.*?)\s*"@\s+-ReferencedAssemblies')
if (-not $match.Success) { throw 'Could not locate embedded C#.' }
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition $match.Groups[1].Value -ReferencedAssemblies @('System.Windows.Forms.dll','System.Drawing.dll')
Add-Type -TypeDefinition @"
using System;
using System.Drawing;
using System.Runtime.InteropServices;
public static class DshDotCapture {
 [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left,Top,Right,Bottom; }
 private delegate bool EnumProc(IntPtr h,IntPtr l);
 [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb,IntPtr l);
 [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
 [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h,out uint p);
 [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h,out RECT r);
 [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h,IntPtr dc,uint flags);
 public static IntPtr Find(int id){IntPtr found=IntPtr.Zero;EnumWindows(delegate(IntPtr h,IntPtr l){uint p;GetWindowThreadProcessId(h,out p);if(p==(uint)id&&IsWindowVisible(h)&&GetWindowTextLength(h)>0){found=h;return false;}return true;},IntPtr.Zero);return found;}
 public static bool SetDpiAware(){return SetProcessDPIAware();}
 public static void Save(IntPtr h,string path){RECT r;if(!GetClientRect(h,out r))throw new System.ComponentModel.Win32Exception();using(Bitmap b=new Bitmap(r.Right-r.Left,r.Bottom-r.Top))using(Graphics g=Graphics.FromImage(b)){IntPtr dc=g.GetHdc();bool ok;try{ok=PrintWindow(h,dc,2);}finally{g.ReleaseHdc(dc);}if(!ok)throw new Exception("PrintWindow returned false.");b.Save(path,System.Drawing.Imaging.ImageFormat.Png);}}
}
"@ -ReferencedAssemblies @('System.Drawing.dll')
[void][DshDotCapture]::SetDpiAware()

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$work = Join-Path ([IO.Path]::GetTempPath()) ('dsh-dot-capture-' + [guid]::NewGuid().ToString('N'))
$runDir = Join-Path (Split-Path -Parent $SourcePath) '.run'
$before = @()
if (Test-Path -LiteralPath $runDir) { $before = @(Get-ChildItem -LiteralPath $runDir -File | ForEach-Object { "$($_.Name)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" } | Sort-Object) }
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$quote = [char]34
$args = "-NoProfile -ExecutionPolicy Bypass -File $quote$SourcePath$quote -Preview -PreviewSeconds $PreviewSeconds -WorkDir $quote$work$quote"
$child = Start-Process -FilePath $psExe -ArgumentList $args -WindowStyle Hidden -PassThru
try {
    $hwnd = [IntPtr]::Zero
    $ready = [Diagnostics.Stopwatch]::StartNew()
    while (-not $child.HasExited -and $ready.Elapsed.TotalSeconds -lt 15 -and $hwnd -eq [IntPtr]::Zero) {
        $child.Refresh(); $hwnd = [DshDotCapture]::Find($child.Id)
        if ($hwnd -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 50 }
    }
    if ($hwnd -eq [IntPtr]::Zero) { throw 'Actual Preview HWND not found.' }
    $client = New-Object DshDotCapture+RECT
    [void][DshDotCapture]::GetClientRect($hwnd,[ref]$client)
    Write-Output "Target Preview client: $($client.Right-$client.Left)x$($client.Bottom-$client.Top)"
    for ($i=0; $i -lt $FrameCount; $i++) {
        $path = Join-Path $OutputDir ('dots-{0:D2}.png' -f $i)
        [DshDotCapture]::Save($hwnd,$path)
        Start-Sleep -Milliseconds $IntervalMs
    }
    Copy-Item -LiteralPath (Join-Path $OutputDir ('dots-{0:D2}.png' -f ($FrameCount-1))) -Destination (Join-Path $OutputDir 'validation-native-preview.png') -Force
    $child.WaitForExit(); $child.Refresh()
    if ($child.ExitCode -ne 0) { throw "Preview exited with code $($child.ExitCode)." }
    if (Test-Path -LiteralPath $work) { throw 'Preview created WorkDir.' }
    $after = @()
    if (Test-Path -LiteralPath $runDir) { $after = @(Get-ChildItem -LiteralPath $runDir -File | ForEach-Object { "$($_.Name)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" } | Sort-Object) }
    if (Compare-Object -ReferenceObject $before -DifferenceObject $after) { throw 'Preview modified .run.' }
    Write-Output "PASS: captured $FrameCount frames from visible HWND PID $($child.Id), interval ${IntervalMs}ms, ExitCode $($child.ExitCode); WorkDir/.run unchanged."
} finally { if (-not $child.HasExited) { Stop-Process -Id $child.Id -Force } }
