# Stop the windowless DeepSeek Harness server started by start-dsh.ps1.
#
# The server has no console any more, so closing a window is no longer how you
# stop it. This kills whatever is listening on the port and clears the cached
# token URL so the next click cold-boots cleanly.
param(
    [int]$Port = 4080,
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
$configFile = Join-Path $PSScriptRoot 'dsh-launcher.json'
if (-not $PSBoundParameters.ContainsKey('Port') -and (Test-Path -LiteralPath $configFile)) {
    try {
        $cfg = Get-Content -LiteralPath $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($cfg.port) { $Port = [int]$cfg.port }
    } catch { }
}
$stateFile = Join-Path (Join-Path $PSScriptRoot '.run') 'state.json'

$target = 0
try {
    $c = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop | Select-Object -First 1
    if ($null -ne $c) { $target = [int]$c.OwningProcess }
} catch { }

if ($target -eq 0) {
    if (-not $Quiet) { Write-Host "dsh: nothing is listening on port $Port." }
} else {
    $name = (Get-Process -Id $target -ErrorAction SilentlyContinue).ProcessName
    Stop-Process -Id $target -Force -ErrorAction SilentlyContinue
    if (-not $Quiet) { Write-Host "dsh: stopped $name (PID $target) on port $Port." }
}

Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue
