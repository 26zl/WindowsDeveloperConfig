<#
.SYNOPSIS
  Stages upstream's PowerShell dev-config flow without the RemoteDesktop step and runs it.
.DESCRIPTION
  Copies src\windows-dev-config\dev-config.ps1 and steps\ to a folder that survives a reboot,
  removes the RemoteDesktop tweak from steps\registry-system.ps1, verifies that nothing in the
  staged copy still references fDenyTSConnections, guards the Lxss registry key in steps\wsl.ps1
  so existing WSL distro registrations are never wiped, optionally trims the staged copy
  (-SkipSteps, -SkipPackages, -KeepNotifications) and launches dev-config.ps1 -AllowUnsigned on
  PowerShell 7. The flow elevates itself through UAC and resumes from the staged folder if it
  has to reboot. Upstream files in the checkout are never modified.
.PARAMETER InstallRoot
  Where the staged copy lives. Defaults to %LOCALAPPDATA%\CalmOS-nordp.
.PARAMETER SkipSteps
  Phases to leave out. Their files are deleted from the staged steps\ folder; dev-config.ps1
  skips a phase whose file is missing. Skipping 'wsl' also removes the only reboot path.
.PARAMETER SkipPackages
  winget package IDs to remove from the staged steps\packages.ps1, e.g. GitHub.Copilot.
  Each ID has to match exactly one entry.
.PARAMETER KeepNotifications
  Removes the DoNotDisturb tweak from the staged steps\registry-taskbar-search.ps1, so toasts
  (Defender, Controlled Folder Access, BitLocker, update restarts) stay visible.
.PARAMETER NoLaunch
  Stage and verify only, then print the command to run.
#>
[CmdletBinding()]
param(
    [string] $InstallRoot = (Join-Path $env:LOCALAPPDATA 'CalmOS-nordp'),
    [ValidateSet('prerequisites', 'packages', 'registry-system', 'registry-explorer', 'registry-taskbar-search',
        'edge', 'fonts', 'terminal', 'powershell-profile', 'copilot', 'wsl')]
    [string[]] $SkipSteps = @(),
    [string[]] $SkipPackages = @(),
    [switch] $KeepNotifications,
    [switch] $NoLaunch
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Rewrites the single line matching $Pattern in a staged file. $Replacement receives the line and
# returns its replacement; without it the line is removed. Anything other than exactly one match
# means upstream changed the file, so the run stops instead of guessing.
function Edit-StagedLine {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Pattern,
        [Parameter(Mandatory)] [string] $What,
        [scriptblock] $Replacement
    )
    $lines = [System.IO.File]::ReadAllLines($Path)
    $hits  = @($lines | Where-Object { $_ -match $Pattern })
    if ($hits.Count -ne 1) {
        throw "Expected exactly one $What in $Path, found $($hits.Count). Upstream changed the file; review it before running."
    }
    $kept = foreach ($line in $lines) {
        if ($line -notmatch $Pattern) {
            $line
        } elseif ($Replacement) {
            & $Replacement $line
        }
    }
    [System.IO.File]::WriteAllLines($Path, @($kept), [System.Text.UTF8Encoding]::new($false))
}

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

$changes = [System.Collections.Generic.List[string]]::new()

Edit-StagedLine -Path (Join-Path $stagedSteps 'registry-system.ps1') -Pattern "Name\s*=\s*'RemoteDesktop'" -What 'RemoteDesktop entry'
$changes.Add('RemoteDesktop removed from steps\registry-system.ps1')

$leftovers = @(Get-ChildItem -LiteralPath $stagedSteps -Filter '*.ps1' -File |
    Select-String -Pattern 'fDenyTSConnections' -List)
if ($leftovers.Count -gt 0) {
    throw "fDenyTSConnections is still referenced in: $(($leftovers | ForEach-Object { $_.Path }) -join ', ')"
}

# Upstream calls New-Item -Force on HKCU:\...\Lxss before installing Ubuntu. In the registry
# provider, -Force on an existing key deletes its values and subkeys, and the subkeys of Lxss are
# the WSL distro registrations. The install step runs whenever no Ubuntu* distro is listed, so a
# machine with only Debian or docker-desktop would lose those registrations.
$wslFile     = Join-Path $stagedSteps 'wsl.ps1'
$lxssPattern = '^\s*New-Item\s+-Path\s+\$lxssPath\s+-Force\s*\|\s*Out-Null\s*$'
Edit-StagedLine -Path $wslFile -Pattern $lxssPattern -What 'unguarded New-Item on $lxssPath' -Replacement {
    param($line)
    $indent = $line -replace '^(\s*).*$', '$1'
    "${indent}if (-not (Test-Path -LiteralPath `$lxssPath)) { New-Item -Path `$lxssPath -Force | Out-Null }"
}
$unguarded = @(Select-String -LiteralPath $wslFile -Pattern 'New-Item\s+-Path\s+\$lxssPath' |
    Where-Object { $_.Line -notmatch 'Test-Path' })
if ($unguarded.Count -gt 0) {
    throw "steps\wsl.ps1 still creates the Lxss key without a Test-Path guard (line $($unguarded[0].LineNumber))."
}
$changes.Add('Lxss key guarded in steps\wsl.ps1 (existing WSL distros stay registered)')

if ($KeepNotifications) {
    Edit-StagedLine -Path (Join-Path $stagedSteps 'registry-taskbar-search.ps1') -Pattern "Name\s*=\s*'DoNotDisturb'" -What 'DoNotDisturb entry'
    $changes.Add('DoNotDisturb removed from steps\registry-taskbar-search.ps1')
}

if ($SkipPackages.Count -gt 0) {
    if ($SkipSteps -contains 'packages') {
        Write-Warning '-SkipPackages has no effect because the packages phase is skipped.'
    } else {
        foreach ($id in $SkipPackages) {
            Edit-StagedLine -Path (Join-Path $stagedSteps 'packages.ps1') -Pattern "Id\s*=\s*'$([regex]::Escape($id))'" -What "package entry for $id"
            $changes.Add("$id removed from steps\packages.ps1")
        }
    }
}

# Phases are dropped last, so the checks above always run against the full upstream copy.
foreach ($step in $SkipSteps) {
    Remove-Item -LiteralPath (Join-Path $stagedSteps "$step.ps1") -Force
    $changes.Add("phase $step skipped")
}

# Files that came from a ZIP download carry the mark of the web, which the flow refuses to load.
Get-ChildItem -LiteralPath $InstallRoot -Recurse -Filter '*.ps1' -File | Unblock-File

$target  = Join-Path $InstallRoot 'dev-config.ps1'
$command = "& '$($pwsh.Source)' -NoProfile -File '$target' -AllowUnsigned"
Write-Host "Staged the RDP-free copy in $InstallRoot."
foreach ($change in $changes) {
    Write-Host "  - $change"
}

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
