<#
.SYNOPSIS
  Stages upstream's PowerShell dev-config flow without the RemoteDesktop step and runs it.
.DESCRIPTION
  Copies src\windows-dev-config\dev-config.ps1 and steps\ to a folder that survives a reboot,
  removes the RemoteDesktop tweak from steps\registry-system.ps1, verifies that nothing in the
  staged copy still references fDenyTSConnections, optionally trims the staged copy
  (-SkipSteps, -SkipPackages, -SkipTweaks, -KeepNotifications) and launches dev-config.ps1 -AllowUnsigned on
  PowerShell 7 with upstream's default action (Full). The flow elevates itself through UAC and
  resumes from the staged folder if it has to reboot. Upstream files in the checkout are never
  modified. Entries are removed as whole blocks, so both the one-line layout and the multi-line
  @{ ... } layout upstream switched to in #108 work.
.PARAMETER InstallRoot
  Where the staged copy lives. Defaults to %LOCALAPPDATA%\CalmOS-nordp.
.PARAMETER SkipSteps
  Phases to leave out. Their files are deleted from the staged steps\ folder; dev-config.ps1
  skips a phase whose file is missing. Skipping 'wsl' also removes the only reboot path.
.PARAMETER SkipPackages
  winget package IDs to remove from the staged steps\packages.ps1, e.g. GitHub.Copilot.
  Each ID has to match exactly one entry.
.PARAMETER SkipTweaks
  Names of single registry tweaks to remove from the staged steps\registry-*.ps1 and
  steps\edge.ps1, e.g. Sudo. Each name has to match exactly one entry. A tweak that cannot be
  written stops the whole run unless upstream marks it BestEffort. WidgetServiceOff, which
  UCPD.sys blocks even elevated, has been BestEffort since #108, so it no longer needs skipping.
.PARAMETER KeepNotifications
  Same as -SkipTweaks DoNotDisturb: toasts (Defender, Controlled Folder Access, BitLocker,
  update restarts) stay visible.
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
    [string[]] $SkipTweaks = @(),
    [switch] $KeepNotifications,
    [switch] $NoLaunch
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Removes the entry whose line matches $Pattern from a staged file. Upstream writes an entry either
# on one line (@{ Name = 'X'; ... }) or, since #108, as a block that opens with a bare "@{" and
# closes with a bare "}"; a block is removed whole. Anything other than exactly one match means
# upstream changed the file, so the run stops instead of guessing.
function Remove-StagedEntry {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Pattern,
        [Parameter(Mandatory)] [string] $What
    )
    $lines = [System.IO.File]::ReadAllLines($Path)
    $hits  = @(0..($lines.Count - 1) | Where-Object { $lines[$_] -match $Pattern })
    if ($hits.Count -ne 1) {
        throw "Expected exactly one $What in $Path, found $($hits.Count). Upstream changed the file; review it before running."
    }
    $first = $last = $hits[0]
    if ($lines[$first] -notmatch '^\s*@\{.*\}\s*$') {
        while ($first -gt 0 -and $lines[$first] -notmatch '^\s*@\{\s*$') { $first-- }
        while ($last -lt $lines.Count - 1 -and $lines[$last] -notmatch '^\s*\}\s*$') { $last++ }
        if ($lines[$first] -notmatch '^\s*@\{\s*$' -or $lines[$last] -notmatch '^\s*\}\s*$') {
            throw "Could not find where the $What in $Path starts and ends. Upstream changed the file; review it before running."
        }
    }
    $kept = @($lines | Select-Object -First $first) + @($lines | Select-Object -Skip ($last + 1))
    [System.IO.File]::WriteAllLines($Path, [string[]]$kept, [System.Text.UTF8Encoding]::new($false))
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

Remove-StagedEntry -Path (Join-Path $stagedSteps 'registry-system.ps1') -Pattern "Name\s*=\s*'RemoteDesktop'" -What 'RemoteDesktop entry'
$changes.Add('RemoteDesktop removed from steps\registry-system.ps1')

$leftovers = @(Get-ChildItem -LiteralPath $stagedSteps -Filter '*.ps1' -File |
    Select-String -Pattern 'fDenyTSConnections' -List)
if ($leftovers.Count -gt 0) {
    throw "fDenyTSConnections is still referenced in: $(($leftovers | ForEach-Object { $_.Path }) -join ', ')"
}

$tweakNames = @($SkipTweaks)
if ($KeepNotifications -and $tweakNames -notcontains 'DoNotDisturb') {
    $tweakNames += 'DoNotDisturb'
}
$tweakFiles = @(Get-ChildItem -LiteralPath $stagedSteps -File | Where-Object { $_.Name -like 'registry-*.ps1' -or $_.Name -eq 'edge.ps1' })
foreach ($tweak in $tweakNames) {
    $pattern = "Name\s*=\s*'$([regex]::Escape($tweak))'"
    $owners  = @($tweakFiles | Where-Object { Select-String -LiteralPath $_.FullName -Pattern $pattern -Quiet })
    if ($owners.Count -ne 1) {
        throw "Expected the tweak '$tweak' in exactly one of the staged registry step files, found it in $($owners.Count)."
    }
    Remove-StagedEntry -Path $owners[0].FullName -Pattern $pattern -What "$tweak entry"
    $changes.Add("$tweak removed from steps\$($owners[0].Name)")
}

if ($SkipPackages.Count -gt 0) {
    if ($SkipSteps -contains 'packages') {
        Write-Warning '-SkipPackages has no effect because the packages phase is skipped.'
    } else {
        foreach ($id in $SkipPackages) {
            Remove-StagedEntry -Path (Join-Path $stagedSteps 'packages.ps1') -Pattern "Id\s*=\s*'$([regex]::Escape($id))'" -What "package entry for $id"
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
