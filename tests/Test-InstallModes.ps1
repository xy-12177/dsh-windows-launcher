# Exercise the real installer in a temporary tree with desktop/COM operations
# intercepted. No real shortcut, profile or installed launcher is changed.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('dsh-install-test-' + [guid]::NewGuid().ToString('N'))
$oldLocalAppData = $env:LOCALAPPDATA
try {
    $fixtureRepo = Join-Path $fixture 'repo'
    $sourceDir = Join-Path $fixtureRepo 'launcher'
    $desktop = Join-Path $fixture 'desktop'
    $env:LOCALAPPDATA = Join-Path $fixture 'local'
    New-Item -ItemType Directory -Path $sourceDir, $desktop, $env:LOCALAPPDATA -Force | Out-Null
    Copy-Item -Path (Join-Path $repo 'launcher\*') -Destination $sourceDir
    $work = Join-Path $fixtureRepo 'work'
    $configPath = Join-Path $sourceDir 'dsh-launcher.json'
    @{port=4899;workDir=$work;appWindow=$true} | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8
    $script = Get-Content -LiteralPath (Join-Path $repo 'install.ps1') -Raw
    $script = $script.Replace('$PSScriptRoot', ("'" + $fixtureRepo.Replace("'", "''") + "'"))
    $script = $script.Replace("[Environment]::GetFolderPath('Desktop')", ("'" + $desktop.Replace("'", "''") + "'"))
    $installer = [scriptblock]::Create($script)
    $script:link = [pscustomobject]@{TargetPath='old-target';Arguments='old-args';WorkingDirectory='old-work';IconLocation='original-icon.ico,0';Description='old-description'}
    $script:saved = 0
    $script:link | Add-Member -MemberType ScriptMethod -Name Save -Value { $script:saved++ }
    $script:shell = [pscustomobject]@{}
    $script:shell | Add-Member -MemberType ScriptMethod -Name CreateShortcut -Value { param($path) $script:linkPath=$path; return $script:link }
    function New-Object {
        [CmdletBinding(PositionalBinding=$false)]
        param([Parameter(Position=0)][string]$TypeName, [string]$ComObject, [Parameter(Position=1)][object[]]$ArgumentList)
        if ($ComObject) {
            if ($ComObject -ne 'WScript.Shell') { throw "Unexpected COM object: $ComObject" }
            return $script:shell
        }
        Microsoft.PowerShell.Utility\New-Object @PSBoundParameters
    }
    function dsh { throw 'Installer must not register a plugin when -SkipPlugin is passed.' }

    $existingPath = Join-Path $desktop 'deepseek harness.lnk'
    [IO.File]::WriteAllText($existingPath, 'fake-shortcut')
    & $installer -UseSource -SkipPlugin
    $cfg = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    if ($cfg.port -ne 4899 -or $cfg.workDir -ne $work -or -not $cfg.appWindow) { throw 'Source installation lost existing config.' }
    if ($script:link.Arguments -ne ('"' + (Join-Path $sourceDir 'start-dsh.vbs') + '"')) { throw 'Source shortcut points at a copy.' }
    if ($script:link.WorkingDirectory -ne $sourceDir -or $script:link.IconLocation -ne 'original-icon.ico,0') { throw 'Source shortcut settings mismatch.' }
    if ($script:linkPath -cne $existingPath) { throw 'Existing shortcut filename was not preserved.' }
    if (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'DeepSeekHarness')) { throw 'Source install created an unnecessary installed copy.' }
    Write-Output 'PASS: source mode preserves config/name/icon, supports a containing workspace and skips plugin registration.'

    & $installer -UseSource -SkipPlugin -Port 4900 -WorkDir $fixture -AppWindow:$false
    $cfg = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    if ($cfg.port -ne 4900 -or $cfg.workDir -ne $fixture -or $cfg.appWindow) { throw 'Explicit source overrides were ignored.' }
    Write-Output 'PASS: explicit port/workspace/browser flags override the source config.'

    $script:link.IconLocation = ''
    & $installer -UseSource -SkipPlugin -WorkDir $work
    $installed = Join-Path $env:LOCALAPPDATA 'DeepSeekHarness'
    if (-not (Test-Path -LiteralPath (Join-Path $installed 'deepseek-harness.ico'))) { throw 'New source shortcut icon was not installed.' }
    if (Test-Path -LiteralPath (Join-Path $installed 'start-dsh.ps1')) { throw 'Source installation copied scripts.' }
    Write-Output 'PASS: a new source shortcut installs only its external icon.'

    & $installer -SkipPlugin -WorkDir $work -Port 4901
    $cfg = Get-Content -LiteralPath (Join-Path $installed 'dsh-launcher.json') -Raw | ConvertFrom-Json
    if ($cfg.port -ne 4901 -or $cfg.workDir -ne $work -or $cfg.appWindow) { throw 'Copy installation settings changed.' }
    if (-not (Test-Path -LiteralPath (Join-Path $installed 'start-dsh.ps1'))) { throw 'Copy installation omitted its scripts.' }
    if ($script:link.Arguments -ne ('"' + (Join-Path $installed 'start-dsh.vbs') + '"')) { throw 'Copy shortcut points at the source.' }
    if ($script:saved -ne 4) { throw 'Unexpected shortcut save count.' }
    Write-Output 'PASS: legacy copy installation still copies the launcher and uses its own config.'
} finally {
    $env:LOCALAPPDATA = $oldLocalAppData
    $resolved = [IO.Path]::GetFullPath($fixture)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -notlike 'dsh-install-test-*') { throw 'Unexpected installer test cleanup path.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
