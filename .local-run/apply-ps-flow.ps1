<#
.SYNOPSIS
  Stages upstream's PowerShell dev-config flow without the RemoteDesktop step and runs it.
.DESCRIPTION
  Copies src\windows-dev-config\dev-config.ps1 and steps\ to a folder that survives a reboot,
  removes the RemoteDesktop tweak from steps\registry-system.ps1, verifies that nothing in the
  staged copy still references fDenyTSConnections, and launches dev-config.ps1 -AllowUnsigned on
  PowerShell 7. The flow elevates itself through UAC and resumes from the staged folder if it
  has to reboot. Upstream files in the checkout are never modified.
.PARAMETER InstallRoot
  Where the staged copy lives. Defaults to %LOCALAPPDATA%\CalmOS-nordp.
.PARAMETER NoLaunch
  Stage and verify only, then print the command to run.
#>
[CmdletBinding()]
param(
    [string] $InstallRoot = (Join-Path $env:LOCALAPPDATA 'CalmOS-nordp'),
    [switch] $NoLaunch
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repo   = Split-Path -Parent $PSScriptRoot
$source = Join-Path $repo 'src\windows-dev-config'
foreach ($name in 'dev-config.ps1', 'steps') {
    if (-not (Test-Path -LiteralPath (Join-Path $source $name))) {
        throw "Not found: $(Join-Path $source $name). This needs a checkout that includes upstream's PowerShell flow."
    }
}

$pwsh = Get-Command 'pwsh.exe' -ErrorAction SilentlyContinue
if (-not $pwsh) {
    throw 'pwsh.exe is required. Install PowerShell 7 first.'
}

# steps\ is recreated every time; devconfig-log.txt and devconfig-tally.json in the root survive so a resumed run keeps them.
$stagedSteps = Join-Path $InstallRoot 'steps'
New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
if (Test-Path -LiteralPath $stagedSteps) {
    Remove-Item -LiteralPath $stagedSteps -Recurse -Force
}
Copy-Item -LiteralPath (Join-Path $source 'dev-config.ps1') -Destination $InstallRoot -Force
Copy-Item -LiteralPath (Join-Path $source 'steps') -Destination $stagedSteps -Recurse -Force

$stepFile = Join-Path $stagedSteps 'registry-system.ps1'
$lines    = [System.IO.File]::ReadAllLines($stepFile)
$kept     = @($lines | Where-Object { $_ -notmatch "Name\s*=\s*'RemoteDesktop'" })
$removed  = $lines.Count - $kept.Count
if ($removed -ne 1) {
    throw "Expected exactly one RemoteDesktop entry in $stepFile, found $removed. Upstream changed the file; review it before running."
}
[System.IO.File]::WriteAllLines($stepFile, $kept, [System.Text.UTF8Encoding]::new($false))

$leftovers = @(Get-ChildItem -LiteralPath $stagedSteps -Filter '*.ps1' -File |
    Select-String -Pattern 'fDenyTSConnections' -List)
if ($leftovers.Count -gt 0) {
    throw "fDenyTSConnections is still referenced in: $(($leftovers | ForEach-Object { $_.Path }) -join ', ')"
}

# Files that came from a ZIP download carry the mark of the web, which the flow refuses to load.
Get-ChildItem -LiteralPath $InstallRoot -Recurse -Filter '*.ps1' -File | Unblock-File

$target  = Join-Path $InstallRoot 'dev-config.ps1'
$command = "& '$($pwsh.Source)' -NoProfile -File '$target' -AllowUnsigned"
Write-Host "Staged the RDP-free copy in $InstallRoot (RemoteDesktop removed from steps\registry-system.ps1)."

if ($NoLaunch) {
    Write-Host 'Run it when ready:'
    Write-Host "  $command"
    return
}

Write-Host 'Starting dev-config.ps1 -AllowUnsigned (a UAC prompt follows)...'
$proc = Start-Process -FilePath $pwsh.Source -ArgumentList @('-NoProfile', '-File', "`"$target`"", '-AllowUnsigned') -NoNewWindow -Wait -PassThru
if ($proc.ExitCode -ne 0) {
    Write-Host "dev-config.ps1 exited with code $($proc.ExitCode). Log: $(Join-Path $InstallRoot 'devconfig-log.txt')"
}
exit $proc.ExitCode
