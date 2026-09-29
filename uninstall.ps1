# Undo install.ps1: stop the server, remove the shortcut, the launcher folder
# and the dsh-auto-shutdown plugin. Your dsh workspace is left untouched.
param(
    [string]$DshProfile = 'web',
    [switch]$KeepPlugin
)

$ErrorActionPreference = 'Continue'
$dest = Join-Path $env:LOCALAPPDATA 'DeepSeekHarness'

$stop = Join-Path $dest 'stop-dsh.ps1'
if (Test-Path -LiteralPath $stop) { & $stop -Quiet }

$lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'DeepSeek Harness.lnk'
Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue

foreach ($f in @('start-dsh.vbs', 'start-dsh.ps1', 'stop-dsh.ps1', 'deepseek-harness.ico', 'deepseek-logo.png', 'dsh-launcher.json')) {
    Remove-Item -LiteralPath (Join-Path $dest $f) -Force -ErrorAction SilentlyContinue
}
Remove-Item -LiteralPath (Join-Path $dest '.run') -Recurse -Force -ErrorAction SilentlyContinue
if ((Test-Path -LiteralPath $dest) -and -not (Get-ChildItem -LiteralPath $dest -Force)) {
    Remove-Item -LiteralPath $dest -Force
}

if (-not $KeepPlugin -and $null -ne (Get-Command dsh -ErrorAction SilentlyContinue)) {
    & dsh plugin --profile $DshProfile remove dsh-auto-shutdown
}

Write-Host 'Uninstalled.'
