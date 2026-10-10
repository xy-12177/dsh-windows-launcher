param([string]$SourcePath = (Join-Path $PSScriptRoot '..\launcher\start-dsh.ps1'))
$ErrorActionPreference = 'Stop'
$tmpRoot = Join-Path $env:TEMP ('dsh-flow-simulation-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
$worker = Join-Path $PSScriptRoot 'LauncherFlowWorker.ps1'
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$results = @()
foreach ($scenario in @('already','cold','failure')) {
    $caseDir = Join-Path $tmpRoot $scenario
    New-Item -ItemType Directory -Path $caseDir -Force | Out-Null
    $result = & $psExe -NoProfile -ExecutionPolicy Bypass -File $worker -Scenario $scenario -SourcePath $SourcePath -SandboxDir $caseDir
    if ($LASTEXITCODE -ne 0) { throw "Simulation failed for ${scenario}: $result" }
    $item = ($result | Select-Object -Last 1) | ConvertFrom-Json
    if ($scenario -eq 'already' -and ($item.Exit -ne 0 -or $item.LaunchCount -ne 0 -or $item.OpenedUrl -ne 'http://127.0.0.1:4080/')) { throw "Already-running simulation failed: $result" }
    if ($scenario -eq 'cold' -and ($item.Exit -ne 0 -or $item.LaunchCount -ne 1 -or $item.OpenedUrl -notmatch '\?token=FAKE_TOKEN_123' -or -not $item.StateExists)) { throw "Cold-start simulation failed: $result" }
    if ($scenario -eq 'failure' -and ($item.Exit -ne 1 -or $item.LaunchCount -ne 1 -or $item.Failure -notmatch 'exited with code 7')) { throw "Startup-failure simulation failed: $result" }
    $results += $item
}
Write-Output 'PASS: already-running, cold-start token/state, and startup-failure routes simulated with process and browser operations intercepted; this does not run dsh or a browser.'
$results | Format-Table -AutoSize
