param(
    [ValidateSet('already','cold','failure')][string]$Scenario,
    [string]$SourcePath,
    [string]$SandboxDir
)
$ErrorActionPreference = 'Stop'
$s = Get-Content -LiteralPath $SourcePath -Raw
$formPattern = '(?s)Add-Type\s+-TypeDefinition\s+@"\s*.*?\s*"@\s+-ReferencedAssemblies\s+@\(.*?\)'
$formShim = @'
Add-Type -TypeDefinition @"
public static class DshProgress {
 public static bool Show(string a,string b,string c) { return true; }
 public static bool Show(string a,string b,string c,bool d) { return true; }
 public static bool Show(string a,string b,string c,string d,bool e) { return true; }
 public static void SetStage(int a,string b) { }
 public static void Close() { }
}
"@
'@
$s = [regex]::Replace($s,$formPattern,[System.Text.RegularExpressions.MatchEvaluator]{ param($m) $formShim },1)
$simRunDir = Join-Path $SandboxDir '.run'
$s = $s.Replace('$runDir    = Join-Path $PSScriptRoot ''.run''', ('$runDir    = ''' + $simRunDir.Replace("'","''") + ''''))
$launcherDir = Split-Path -Parent $SourcePath
$literalDir = "'" + $launcherDir.Replace("'","''") + "'"
$s = $s.Replace('$PSScriptRoot',$literalDir)
$s = $s.Replace('exit 0','$global:SimExit = 0; return').Replace('exit 1','$global:SimExit = 1; return')
$shim = @'
function Test-PortListening { if ($global:SimScenario -eq 'already') { return $true }; return $false }
function Get-PortOwnerPid { return 0 }
function Read-SharedText { if ($global:SimScenario -eq 'cold') { return 'http://127.0.0.1:4080/?token=FAKE_TOKEN_123' }; return '' }
function Start-Process { $global:SimLaunchCount++; if ($global:SimScenario -eq 'failure') { return [pscustomobject]@{HasExited=$true; ExitCode=7; Id=777} }; return [pscustomobject]@{HasExited=$false; ExitCode=0; Id=778} }
function Open-Ui { param([string]$Url); $global:SimOpenedUrl = $Url }
function Show-Failure { param([string]$Message); $global:SimFailure = $Message }
'@
$marker = '(?s)try\s*\{\s*# --- launch progress window'
$s = [regex]::Replace($s,$marker,{ param($m) $shim + "`r`ntry {`r`n    # --- launch progress window" },1)
if ($s -eq $source) { throw 'Could not construct the in-memory launcher simulation.' }
$global:SimScenario = $Scenario
$global:SimLaunchCount = 0
$global:SimExit = -1
$global:SimOpenedUrl = ''
$global:SimFailure = ''
$runner = [scriptblock]::Create($s)
& $runner -Port 4080 -WaitMs 1000 -WorkDir (Join-Path $SandboxDir 'work')
[pscustomobject]@{
    Scenario=$Scenario
    Exit=$global:SimExit
    LaunchCount=$global:SimLaunchCount
    OpenedUrl=$global:SimOpenedUrl
    Failure=$global:SimFailure
    StateExists=(Test-Path -LiteralPath (Join-Path $simRunDir 'state.json'))
} | ConvertTo-Json -Compress
