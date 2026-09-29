# One-step installer for dsh-windows-launcher.
#
#   1. Registers this folder as a dsh plugin (dsh-auto-shutdown) in a profile.
#   2. Copies the windowless launcher + progress window to
#      %LOCALAPPDATA%\DeepSeekHarness and writes dsh-launcher.json there.
#   3. Creates a "DeepSeek Harness" shortcut on the desktop.
#
# The plugin is added as a live link to THIS folder, so keep the clone where it
# is (or re-run install.ps1 after moving it).
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File install.ps1
#   powershell -ExecutionPolicy Bypass -File install.ps1 -WorkDir D:\work -Port 4080
param(
    [string]$DshProfile = 'web',
    [int]$Port = 4080,
    [string]$WorkDir = (Join-Path $env:USERPROFILE 'dsh-workspace'),
    [switch]$AppWindow,
    [switch]$SkipPlugin,
    [switch]$SkipLauncher
)

$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot
$dest = Join-Path $env:LOCALAPPDATA 'DeepSeekHarness'

if (-not $SkipPlugin) {
    if ($null -eq (Get-Command dsh -ErrorAction SilentlyContinue)) {
        throw 'dsh is not on PATH. Install it first: npm i -g @deepseek-ai/dsh'
    }
    Write-Host "Adding plugin to dsh profile '$DshProfile'..."
    & dsh plugin --profile $DshProfile add $repo
    if ($LASTEXITCODE -ne 0) { throw "dsh plugin add failed (exit $LASTEXITCODE)." }
}

if (-not $SkipLauncher) {
    # The launcher folder must never be (or sit inside) the dsh workspace: the
    # sandbox labels the workspace Low integrity and Explorer then shows a
    # blank shortcut icon.
    $full = [System.IO.Path]::GetFullPath($WorkDir).TrimEnd('\') + '\'
    if (($dest.TrimEnd('\') + '\').StartsWith($full, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "WorkDir '$WorkDir' contains the launcher folder '$dest'. Pick another WorkDir."
    }
    if (-not (Test-Path -LiteralPath $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }
    if (-not (Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }

    Write-Host "Copying launcher to $dest..."
    Copy-Item -Path (Join-Path $repo 'launcher\*') -Destination $dest -Force

    $cfg = [ordered]@{ port = $Port; workDir = $WorkDir; appWindow = [bool]$AppWindow }
    $json = $cfg | ConvertTo-Json
    [System.IO.File]::WriteAllText((Join-Path $dest 'dsh-launcher.json'), $json, (New-Object System.Text.UTF8Encoding($false)))

    $desktop = [Environment]::GetFolderPath('Desktop')
    $lnkPath = Join-Path $desktop 'DeepSeek Harness.lnk'
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($lnkPath)
    $lnk.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $lnk.Arguments = '"' + (Join-Path $dest 'start-dsh.vbs') + '"'
    $lnk.WorkingDirectory = $dest
    $lnk.IconLocation = (Join-Path $dest 'deepseek-harness.ico') + ',0'
    $lnk.Description = 'DeepSeek Harness Web UI'
    $lnk.Save()
    Write-Host "Shortcut created: $lnkPath"
}

Write-Host ''
Write-Host 'Done. If a dsh web server is already running, stop it first so the plugin loads:'
Write-Host "  powershell -File `"$(Join-Path $dest 'stop-dsh.ps1')`""
