# One-step installer for dsh-windows-launcher.
#
#   1. Registers this folder as a dsh plugin (dsh-auto-shutdown) in a profile.
#   2. Copies the windowless launcher + progress window to
#      %LOCALAPPDATA%\DeepSeekHarness and writes dsh-launcher.json there.
#   3. Creates a "DeepSeek Harness" shortcut on the desktop.
#      -UseSource points it at launcher/ without copying the scripts.
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
    [switch]$SkipLauncher,
    [switch]$UseSource
)

$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot
$installedDir = Join-Path $env:LOCALAPPDATA 'DeepSeekHarness'
$dest = $installedDir
if ($UseSource) { $dest = Join-Path $repo 'launcher' }

# Re-running source installation should retain the local launch settings unless
# the caller explicitly overrides them. Copy installation keeps its old defaults.
$configFile = Join-Path $dest 'dsh-launcher.json'
if ($UseSource -and -not $SkipLauncher -and (Test-Path -LiteralPath $configFile)) {
    $currentConfig = Get-Content -LiteralPath $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $PSBoundParameters.ContainsKey('Port') -and $currentConfig.port) { $Port = [int]$currentConfig.port }
    if (-not $PSBoundParameters.ContainsKey('WorkDir') -and $currentConfig.workDir) { $WorkDir = [string]$currentConfig.workDir }
    if (-not $PSBoundParameters.ContainsKey('AppWindow')) { $AppWindow = [switch][bool]$currentConfig.appWindow }
}

if (-not $SkipPlugin) {
    if ($null -eq (Get-Command dsh -ErrorAction SilentlyContinue)) {
        throw 'dsh is not on PATH. Install it first: npm i -g @deepseek-ai/dsh'
    }
    Write-Host "Adding plugin to dsh profile '$DshProfile'..."
    & dsh plugin --profile $DshProfile add $repo
    if ($LASTEXITCODE -ne 0) { throw "dsh plugin add failed (exit $LASTEXITCODE)." }
}

if (-not $SkipLauncher) {
    # Copy installation keeps executable assets outside the workspace. Source
    # installation may live inside it, but the shortcut icon must remain outside:
    # dsh's sandbox can label the workspace Low integrity.
    $full = [System.IO.Path]::GetFullPath($WorkDir).TrimEnd('\') + '\'
    if (-not $UseSource -and ($dest.TrimEnd('\') + '\').StartsWith($full, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "WorkDir '$WorkDir' contains the launcher folder '$dest'. Pick another WorkDir."
    }
    if ($UseSource) {
        foreach ($asset in @('start-dsh.vbs', 'start-dsh.ps1', 'stop-dsh.ps1', 'deepseek-logo.png', 'whale-maid-static.png', 'deepseek-harness.ico')) {
            if (-not (Test-Path -LiteralPath (Join-Path $dest $asset) -PathType Leaf)) { throw "Source launcher asset missing: $asset" }
        }
    }
    if (-not (Test-Path -LiteralPath $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }
    if (-not (Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }

    if ($UseSource) {
        Write-Host "Using launcher source at $dest..."
    } else {
        Write-Host "Copying launcher to $dest..."
        Copy-Item -Path (Join-Path $repo 'launcher\*') -Destination $dest -Force
    }

    $cfg = [ordered]@{ port = $Port; workDir = $WorkDir; appWindow = [bool]$AppWindow }
    $json = $cfg | ConvertTo-Json
    [System.IO.File]::WriteAllText($configFile, $json, (New-Object System.Text.UTF8Encoding($false)))

    $desktop = [Environment]::GetFolderPath('Desktop')
    $lnkPath = Join-Path $desktop 'DeepSeek Harness.lnk'
    $existingLink = Get-ChildItem -LiteralPath $desktop -Filter 'DeepSeek Harness.lnk' | Select-Object -First 1
    if ($null -ne $existingLink) { $lnkPath = $existingLink.FullName }
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($lnkPath)
    $iconLocation = $lnk.IconLocation
    if (-not $UseSource -or [string]::IsNullOrWhiteSpace($iconLocation)) {
        $iconFile = Join-Path $installedDir 'deepseek-harness.ico'
        if ($UseSource) {
            if (($installedDir.TrimEnd('\') + '\').StartsWith($full, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "WorkDir '$WorkDir' contains the shortcut icon folder '$installedDir'. Pick another WorkDir."
            }
            if (-not (Test-Path -LiteralPath $installedDir)) { New-Item -ItemType Directory -Path $installedDir -Force | Out-Null }
            Copy-Item -LiteralPath (Join-Path $dest 'deepseek-harness.ico') -Destination $iconFile -Force
        }
        $iconLocation = $iconFile + ',0'
    }
    $lnk.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $lnk.Arguments = '"' + (Join-Path $dest 'start-dsh.vbs') + '"'
    $lnk.WorkingDirectory = $dest
    $lnk.IconLocation = $iconLocation
    $lnk.Description = 'DeepSeek Harness Web UI'
    $lnk.Save()
    Write-Host "Shortcut created: $lnkPath"
}

Write-Host ''
Write-Host 'Done. If a dsh web server is already running, stop it first so the plugin loads:'
Write-Host "  powershell -File `"$(Join-Path $dest 'stop-dsh.ps1')`""
