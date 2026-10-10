param(
 [string]$SourcePath=(Join-Path $PSScriptRoot '..\launcher\start-dsh.ps1'),
 [string]$OutputDir=(Join-Path $PSScriptRoot '..\images'),
 [string]$Label='current',
 [int]$PreviewSeconds=8
)
$ErrorActionPreference='Stop'
$source=Get-Content -LiteralPath $SourcePath -Raw
$m=[regex]::Match($source,'(?s)Add-Type\s+-TypeDefinition\s+@"\s*(.*?)\s*"@\s+-ReferencedAssemblies')
if(-not $m.Success){throw 'Embedded C# missing.'}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition $m.Groups[1].Value -ReferencedAssemblies @('System.Windows.Forms.dll','System.Drawing.dll')
Add-Type -TypeDefinition @"
using System; using System.Drawing; using System.Runtime.InteropServices; using System.Windows.Forms;
public static class DshNativeRegionProbe {
 [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left,Top,Right,Bottom; }
 [DllImport("user32.dll",SetLastError=true)] public static extern int GetWindowRgn(IntPtr h,IntPtr r);
 [DllImport("user32.dll",SetLastError=true)] public static extern int GetWindowRgnBox(IntPtr h,out RECT r);
 [DllImport("gdi32.dll")] public static extern IntPtr CreateRectRgn(int l,int t,int r,int b);
 [DllImport("gdi32.dll")] public static extern bool PtInRegion(IntPtr r,int x,int y);
 [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr o);
 [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h,out RECT r);
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out RECT r);
 [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h,IntPtr dc,uint f);
 private delegate bool EnumProc(IntPtr h,IntPtr l);
 [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb,IntPtr l);
 [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
 [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h,out uint p);
 public static IntPtr FindWindow(int id){IntPtr x=IntPtr.Zero;EnumWindows(delegate(IntPtr h,IntPtr l){uint p;GetWindowThreadProcessId(h,out p);if(p==(uint)id&&IsWindowVisible(h)&&GetWindowTextLength(h)>0){x=h;return false;}return true;},IntPtr.Zero);return x;}
 public static void Resize(Form f,int w,int h){f.Invoke((MethodInvoker)delegate{f.ClientSize=new Size(w,h);});}
 public static void SaveWindow(IntPtr h,string path){RECT r;GetWindowRect(h,out r);using(Bitmap b=new Bitmap(r.Right-r.Left,r.Bottom-r.Top))using(Graphics g=Graphics.FromImage(b)){IntPtr dc=g.GetHdc();bool ok;try{ok=PrintWindow(h,dc,2);}finally{g.ReleaseHdc(dc);}if(ok)b.Save(path,System.Drawing.Imaging.ImageFormat.Png);}}
}
"@ -ReferencedAssemblies @('System.Windows.Forms.dll','System.Drawing.dll')
function Test-Region([IntPtr]$Hwnd,[string]$Tag,[double]$Scale){
 $r=[DshNativeRegionProbe]::CreateRectRgn(0,0,0,0)
 try{
  $kind=[DshNativeRegionProbe]::GetWindowRgn($Hwnd,$r);if($kind -eq 0){throw "$Tag GetWindowRgn returned null."}
  $checks=@(
   @{N='panel';X=450;Y=200;V=$true},@{N='head-overhang';X=560;Y=30;V=$true},
   @{N='shoe-left';X=539;Y=324;V=$true},@{N='shoe-right';X=603;Y=324;V=$true},
   @{N='outer-left';X=5;Y=5;V=$false},@{N='outer-right-top';X=750;Y=5;V=$false},
   @{N='outside-right';X=750;Y=200;V=$false},@{N='rounded-cutout';X=25;Y=339;V=$false},
   @{N='transparent-head-neighbor';X=570;Y=30;V=$false})
  foreach($p in $checks){$actual=[DshNativeRegionProbe]::PtInRegion($r,[int][Math]::Round($p.X*$Scale),[int][Math]::Round($p.Y*$Scale));if($actual -ne $p.V){throw "$Tag $($p.N) expected $($p.V), got $actual"};Write-Output "$Tag $($p.N)=$actual"}
  $b=New-Object DshNativeRegionProbe+RECT;[void][DshNativeRegionProbe]::GetWindowRgnBox($Hwnd,[ref]$b)
  Write-Output "$Tag regionType=$kind bounds=$($b.Left),$($b.Top)..$($b.Right),$($b.Bottom)"
 }finally{[void][DshNativeRegionProbe]::DeleteObject($r)}
}
$asset=Split-Path -Parent $SourcePath;$logo=Join-Path $asset 'deepseek-logo.png';$mascot=Join-Path $asset 'whale-maid-static.png'
if(-not [DshProgress]::Show('DeepSeek Harness','正在等待服务就绪…',$logo,$mascot,$true)){throw 'Form failed to show.'}
try{
 $form=[DshProgress].GetField('_form',[Reflection.BindingFlags]'Static,NonPublic').GetValue($null)
 if($null -eq $form -or -not $form.IsHandleCreated){throw 'No live form handle.'}
 $scale=$form.ClientSize.Width/760.0
 if([Math]::Abs($form.ClientSize.Height/360.0-$scale) -gt .03){throw "Unexpected client size $($form.ClientSize)."}
 Test-Region $form.Handle "$Label-initial" $scale
 $sz=$form.ClientSize
 [DshNativeRegionProbe]::Resize($form,$sz.Width+80,$sz.Height+40);Test-Region $form.Handle "$Label-resized" $scale
 [DshNativeRegionProbe]::Resize($form,$sz.Width,$sz.Height);Test-Region $form.Handle "$Label-restored" $scale
}finally{[DshProgress]::Close()}
$work=Join-Path ([IO.Path]::GetTempPath()) ('dsh-v3-preview-'+[guid]::NewGuid().ToString('N'))
$run=Join-Path $asset '.run';$before=@();if(Test-Path $run){$before=@(Get-ChildItem $run -File|%{"$($_.Name)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)"}|Sort-Object)}
$ps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$quote=[char]34;$args="-NoProfile -ExecutionPolicy Bypass -File $quote$SourcePath$quote -Preview -PreviewSeconds $PreviewSeconds -WorkDir $quote$work$quote"
$child=Start-Process $ps -ArgumentList $args -WindowStyle Hidden -PassThru
try{
 $hw=[IntPtr]::Zero;$sw=[Diagnostics.Stopwatch]::StartNew()
 while(-not $child.HasExited -and $sw.Elapsed.TotalSeconds -lt 15 -and $hw -eq [IntPtr]::Zero){$child.Refresh();$hw=[DshNativeRegionProbe]::FindWindow($child.Id);if($hw -eq [IntPtr]::Zero){Start-Sleep -Milliseconds 100}}
 if($hw -eq [IntPtr]::Zero){throw 'Actual Preview HWND not found.'}
 $cr=New-Object DshNativeRegionProbe+RECT;$box=New-Object DshNativeRegionProbe+RECT
 [void][DshNativeRegionProbe]::GetClientRect($hw,[ref]$cr)
 $k=($cr.Right-$cr.Left)/760.0;if([Math]::Abs(($cr.Bottom-$cr.Top)/360.0-$k) -gt .03){throw 'Live Preview client dimensions mismatch.'}
 Test-Region $hw "$Label-live-preview" $k
 [DshNativeRegionProbe]::GetWindowRgnBox($hw,[ref]$box)|Out-Null
 [DshNativeRegionProbe]::SaveWindow($hw,(Join-Path $OutputDir 'validation-native-preview.png'))
 Write-Output "Live PID=$($child.Id) Client=$($cr.Right-$cr.Left)x$($cr.Bottom-$cr.Top) RegionBounds=$($box.Left),$($box.Top)..$($box.Right),$($box.Bottom)"
 $child.WaitForExit();$child.Refresh();if($child.ExitCode -ne 0){throw "Preview ExitCode=$($child.ExitCode)"}
 if(Test-Path $work){throw 'Preview created WorkDir.'}
 $after=@();if(Test-Path $run){$after=@(Get-ChildItem $run -File|%{"$($_.Name)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)"}|Sort-Object)}
 if(Compare-Object $before $after){throw 'Preview changed .run.'}
 Write-Output "PASS Preview ExitCode=$($child.ExitCode), WorkDir/.run unchanged."
}finally{if(-not $child.HasExited){Stop-Process -Id $child.Id -Force}}
