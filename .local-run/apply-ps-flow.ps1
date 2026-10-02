<#
.SYNOPSIS
  Stages upstream's PowerShell dev-config flow without the RemoteDesktop step and runs it.
.DESCRIPTION
  Copies src\windows-dev-config\dev-config.ps1, steps\ and workloads\ to a folder that survives a
  reboot, removes the RemoteDesktop tweak from steps\registry-system.ps1, verifies that nothing in
  the staged copy still references fDenyTSConnections, optionally trims the staged copy
  (-SkipSteps, -SkipPackages, -SkipTweaks, -KeepNotifications) and launches dev-config.ps1 -AllowUnsigned on
  PowerShell 7 with upstream's default workload (devconfig) and action (Full). The flow elevates
  itself through UAC and resumes from the staged folder if it has to reboot. Upstream files in the
  checkout are never modified. Entries are removed as whole @{ ... } blocks (brace-counted), so the
  one-line layout, the multi-line layout from #108 and the nested workload blocks from #125 all work.
.PARAMETER InstallRoot
  Where the staged copy lives. Defaults to %LOCALAPPDATA%\CalmOS-nordp.
.PARAMETER SkipSteps
  Phases to leave out. Since #125 the phase list lives in workloads\devconfig.ps1 and a missing phase
  file is an error, so the phase's entry is removed from the staged workload instead of deleting the
  file. Skipping 'wsl' also removes the only reboot path.
.PARAMETER SkipPackages
  winget package IDs to leave out, e.g. GitHub.Copilot. Since #125 the workload lists catalog names
  (GitHubCopilot) and steps\packages.ps1 maps them to IDs, so the ID is looked up in the staged
  catalog and the name is removed from the staged workload's package list. Each ID has to match
  exactly one catalog entry and one list line.
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

# Finds the single line matching $Pattern in $Lines. Anything other than exactly one match means
# upstream changed the file, so the run stops instead of guessing.
function Find-StagedLine {
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [AllowEmptyCollection()] [string[]] $Lines,
        [Parameter(Mandatory)] [string] $Pattern,
        [Parameter(Mandatory)] [string] $What,
        [Parameter(Mandatory)] [string] $Path
    )
    $hits = @(0..($Lines.Count - 1) | Where-Object { $Lines[$_] -match $Pattern })
    if ($hits.Count -ne 1) {
        throw "Expected exactly one $What in $Path, found $($hits.Count). Upstream changed the file; review it before running."
    }
    return $hits[0]
}

# Returns the first and last line index of the @{ ... } block that contains line $Index, by counting
# braces from the block's opening line. Works for one-line blocks and for blocks with nested
# hashtables or arrays (the workload definitions from #125).
function Get-StagedBlock {
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [AllowEmptyCollection()] [string[]] $Lines,
        [Parameter(Mandatory)] [int] $Index,
        [Parameter(Mandatory)] [string] $What,
        [Parameter(Mandatory)] [string] $Path
    )
    $first = $Index
    while ($first -gt 0 -and $Lines[$first] -notmatch '^\s*@\{') { $first-- }
    if ($Lines[$first] -notmatch '^\s*@\{') {
        throw "Could not find where the $What in $Path starts. Upstream changed the file; review it before running."
    }
    $depth = 0
    for ($last = $first; $last -lt $Lines.Count; $last++) {
        $depth += ([regex]::Matches($Lines[$last], '\{')).Count - ([regex]::Matches($Lines[$last], '\}')).Count
        if ($depth -eq 0) { return @($first, $last) }
    }
    throw "Could not find where the $What in $Path ends. Upstream changed the file; review it before running."
}

function Write-StagedLines {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [AllowEmptyString()] [AllowEmptyCollection()] [string[]] $Lines
    )
    [System.IO.File]::WriteAllLines($Path, $Lines, [System.Text.UTF8Encoding]::new($false))
}

# Removes the whole @{ ... } entry whose line matches $Pattern from a staged file.
function Remove-StagedEntry {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Pattern,
        [Parameter(Mandatory)] [string] $What
    )
    $lines = [System.IO.File]::ReadAllLines($Path)
    $hit = Find-StagedLine -Lines $lines -Pattern $Pattern -What $What -Path $Path
    $first, $last = Get-StagedBlock -Lines $lines -Index $hit -What $What -Path $Path
    $kept = @($lines | Select-Object -First $first) + @($lines | Select-Object -Skip ($last + 1))
    Write-StagedLines -Path $Path -Lines ([string[]]$kept)
}

# Removes the single line matching $Pattern from a staged file.
function Remove-StagedLine {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Pattern,
        [Parameter(Mandatory)] [string] $What
    )
    $lines = [System.IO.File]::ReadAllLines($Path)
    $hit = Find-StagedLine -Lines $lines -Pattern $Pattern -What $What -Path $Path
    $kept = @($lines | Select-Object -First $hit) + @($lines | Select-Object -Skip ($hit + 1))
    Write-StagedLines -Path $Path -Lines ([string[]]$kept)
}

$repo   = Split-Path -Parent $PSScriptRoot
$source = Join-Path $repo 'src\windows-dev-config'
foreach ($name in 'dev-config.ps1', 'steps', 'workloads\devconfig.ps1') {
    if (-not (Test-Path -LiteralPath (Join-Path $source $name))) {
        throw "Not found: $(Join-Path $source $name). This needs a checkout that includes upstream's PowerShell flow (#125 or later)."
    }
}

$pwsh = Get-Command 'pwsh.exe' -ErrorAction SilentlyContinue
if (-not $pwsh) {
    throw 'pwsh.exe is required. Install PowerShell 7 first.'
}

# steps\ and workloads\ are recreated every time; devconfig-log.txt and devconfig-tally.json in the root survive so a resumed run keeps them.
$stagedSteps     = Join-Path $InstallRoot 'steps'
$stagedWorkloads = Join-Path $InstallRoot 'workloads'
New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
foreach ($dir in $stagedSteps, $stagedWorkloads) {
    if (Test-Path -LiteralPath $dir) {
        Remove-Item -LiteralPath $dir -Recurse -Force
    }
}
Copy-Item -LiteralPath (Join-Path $source 'dev-config.ps1') -Destination $InstallRoot -Force
Copy-Item -LiteralPath (Join-Path $source 'steps') -Destination $stagedSteps -Recurse -Force
Copy-Item -LiteralPath (Join-Path $source 'workloads') -Destination $stagedWorkloads -Recurse -Force
$stagedWorkload = Join-Path $stagedWorkloads 'devconfig.ps1'

$changes = [System.Collections.Generic.List[string]]::new()

Remove-StagedEntry -Path (Join-Path $stagedSteps 'registry-system.ps1') -Pattern "Name\s*=\s*'RemoteDesktop'" -What 'RemoteDesktop entry'
$changes.Add('RemoteDesktop removed from steps\registry-system.ps1')

$leftovers = @(Get-ChildItem -LiteralPath $stagedSteps, $stagedWorkloads -Filter '*.ps1' -File |
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
        $catalogPath  = Join-Path $stagedSteps 'packages.ps1'
        $catalogLines = [System.IO.File]::ReadAllLines($catalogPath)
        foreach ($id in $SkipPackages) {
            # The workload lists catalog names; the ID is only in the catalog entry.
            $idLine = Find-StagedLine -Lines $catalogLines -Pattern "Id\s*=\s*'$([regex]::Escape($id))'" -What "catalog entry for $id" -Path $catalogPath
            $first, $last = Get-StagedBlock -Lines $catalogLines -Index $idLine -What "catalog entry for $id" -Path $catalogPath
            $nameLine = @($catalogLines[$first..$last] | Where-Object { $_ -match "^\s*Name\s*=\s*'([^']+)'" })
            if ($nameLine.Count -ne 1) {
                throw "Could not read the catalog name for $id in $catalogPath. Upstream changed the file; review it before running."
            }
            $packageName = [regex]::Match($nameLine[0], "'([^']+)'").Groups[1].Value
            Remove-StagedLine -Path $stagedWorkload -Pattern "^\s*'$([regex]::Escape($packageName))'\s*$" -What "package list line for $packageName ($id)"
            $changes.Add("$id ($packageName) removed from workloads\devconfig.ps1")
        }
    }
}

# Phases are dropped last, so the checks above always run against the full upstream copy.
foreach ($step in $SkipSteps) {
    Remove-StagedEntry -Path $stagedWorkload -Pattern "File\s*=\s*'$([regex]::Escape($step)).ps1'" -What "phase entry for $step"
    $changes.Add("phase $step removed from workloads\devconfig.ps1")
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
