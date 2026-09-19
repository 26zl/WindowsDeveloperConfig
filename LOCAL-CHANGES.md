# Local changes

This is a fork of [microsoft/WindowsDeveloperConfig](https://github.com/microsoft/WindowsDeveloperConfig),
kept in sync with upstream `main` (last merged: `ff7a538`, 2026-09-17). Everything is upstream and
unmodified **except** the files described below and the review fixes listed at the end.

## Windows Dev Config without Remote Desktop

Upstream's Windows Dev Config enables Remote Desktop by setting `fDenyTSConnections = 0`, with the
note *"firewall rule still needs separate enable"*. That assumption does not hold on this machine:
the **Remote Desktop firewall rule is already enabled**, so applying it takes the box from
"RDP blocked" straight to "RDP listening and reachable" in a single step, with no second gate.

Verify the current state with:

```powershell
Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections
# 1 = RDP blocked (desired here)   0 = RDP enabled
Get-NetFirewallRule -DisplayGroup 'Remote Desktop' | Select-Object Name, Enabled
```

Upstream has shipped two generations of the flow. Both stay usable here without the RemoteDesktop
step.

### PowerShell flow (current upstream): `.local-run/apply-ps-flow.ps1`

Upstream replaced the DSC document with `windows-dev-config/bootstrap.ps1`, `dev-config.ps1` and
`steps/*.ps1` in `ff7a538` (2026-09-16). The signed copy at the repo root only runs under the
`AllSigned` execution policy, so a modified copy has to be the unsigned one under `src/` run with
`-AllowUnsigned`, which is exactly how upstream's README says to customize it.

`apply-ps-flow.ps1` does that without touching the checkout:

1. Copies `src\windows-dev-config\dev-config.ps1` and `steps\` to `%LOCALAPPDATA%\CalmOS-nordp`,
   a location that survives the reboot the flow may need.
2. Deletes the `RemoteDesktop` entry from the staged `steps\registry-system.ps1`. It fails if it
   finds anything other than exactly one such entry, or if `fDenyTSConnections` is still referenced
   anywhere under `steps\`.
3. Guards the `Lxss` registry key in the staged `steps\wsl.ps1` (see "Audit fixes" below). It
   fails if it finds anything other than exactly one unguarded `New-Item -Path $lxssPath -Force`.
4. Optionally trims the staged copy: `-SkipSteps` deletes phase files (`dev-config.ps1` skips a
   phase whose file is missing), `-SkipPackages` removes winget IDs from `steps\packages.ps1`, and
   `-KeepNotifications` removes the `DoNotDisturb` tweak. Every removal has to match exactly one
   entry, otherwise the script stops.
5. Runs `pwsh -NoProfile -File <staged>\dev-config.ps1 -AllowUnsigned`. The flow requests UAC by
   itself. `-NoLaunch` stages and prints the command instead of running it.

```powershell
.\.local-run\apply-ps-flow.ps1            # stage + run
.\.local-run\apply-ps-flow.ps1 -NoLaunch  # stage only

# Trimmed run for a machine that already has its own profile, WSL distros and no Copilot:
.\.local-run\apply-ps-flow.ps1 -NoLaunch -KeepNotifications `
    -SkipSteps wsl, copilot, powershell-profile `
    -SkipPackages GitHub.Copilot, CoreyButler.NVMforWindows
```

Not run on this machine yet. Compared with the DSC run of 2026-09-07, this flow also:

- updates winget to the latest GitHub release through `Repair-WinGetPackageManager` and installs
  the `Microsoft.WinGet.Client` module for the current user;
- counts a package as done only when it is installed **and** current, so it upgrades all 15
  packages;
- installs the Cascadia NF fonts machine-wide under `%SystemRoot%\Fonts` and removes the per-user
  copies the DSC run installed;
- round-trips Windows Terminal `settings.json` through `ConvertTo-Json` (backup in
  `settings.json.bak`, comments are lost);
- uses new registry locations for three values: `Explorer\CabinetState\FullPath`,
  `Explorer\Advanced\TaskbarDeveloperSettings\TaskbarEndTask` and
  `Notifications\Settings\Microsoft.PowerToysWin32\Enabled`;
- keeps Sudo in inline mode, Do Not Disturb and the two Edge policies from the DSC version.

WSL: `vmcompute` is registered, `wsl --version` works and Ubuntu is registered, so both WSL steps
report "already OK" and no reboot is expected. If a reboot did happen, the resume task would fall
back to Windows PowerShell 5.1, because PowerShell 7 here is the Store build and
`C:\Program Files\PowerShell\7\pwsh.exe` does not exist.

Run `.\.local-run\capture-state.ps1` first for a fresh revert point. It covers the new registry
locations.

### DSC snapshot (previous upstream): `windows-dev-config/dev-config-nordp.winget`

A copy of upstream `dev-config.winget` as of `b5561d1` with the `RemoteDesktop` resource removed
(12 lines; see `.local-run/remove-remotedesktop.patch`). Upstream deleted `dev-config.winget` and
`install.ps1` in `ff7a538`, so this is a frozen snapshot. The original is available with
`git show b5561d1:windows-dev-config/dev-config.winget`. The patch was cut with plain `diff -u`, so
it applies to a fresh copy of that file with `git apply -p0 --ignore-whitespace`.

Applied on 2026-09-07 (50/50 units, exit 0). To apply again, run from an **elevated**
PowerShell 7:

```powershell
.\.local-run\apply.ps1
```

The script resolves its own paths, refuses to run unelevated, and writes a timestamped log next
to itself. Or invoke winget directly:

```powershell
winget configure --file .\windows-dev-config\dev-config-nordp.winget `
  --accept-configuration-agreements --disable-interactivity
```

## Workloads (applied 2026-09-14)

Applied unmodified from an elevated PowerShell 7: `php`, `typescript`, `java`. Already
satisfied before the run, so not applied: `dotnet`, `go`, `python`, `rust`. The Rust toolchain
links against the VCTools workload in VS Build Tools 2026; upstream's `rust` config would add
VS 2022 Build Tools on top. Skipped by choice: `winforms`, `winui`.

The Java MSI prepends JDK 25 to the machine `PATH`, repoints `JAVA_HOME` from Temurin 21 to
JDK 25, and takes over the `.jar` association.

Two workloads run from local copies, each next to its untouched upstream file:

```powershell
winget configure --file .\Workloads\powershell\configuration-local.winget `
  --accept-configuration-agreements --disable-interactivity
winget configure --file .\Workloads\sql\configuration-local.winget `
  --accept-configuration-agreements --disable-interactivity
```

Both copies install `Microsoft.VSCode.Dsc` with `-Scope AllUsers` instead of
`-Scope CurrentUser`. Controlled Folder Access is on, and it blocks the Store build of `pwsh.exe`
from writing to `Documents\PowerShell\Modules` (Defender event 1123). The CFA allow-list is left
as it is.

### `Workloads/powershell/configuration-local.winget`

`ConfigurePowerShellScriptAnalyzer` is removed. Its `setScript` strips comments from
`%APPDATA%\Code\User\settings.json` with a regex and writes the file back through
`ConvertTo-Json`. Here that file is a symlink into the `vscode_config` repo:

- every comment would be lost;
- the block-comment regex `/\*[\s\S]*?\*/` also matches between glob keys such as
  `"**/.venv/**"` and the next `"**/`, swallowing real settings (fixed in `src/`, see below, but
  the round-trip through `ConvertTo-Json` remains);
- the unit writes an absolute `C:\Users\...` path, which the machine-path guard in
  `vscode_config/test.sh` rejects.

To use its PSScriptAnalyzer rules, put a `PSScriptAnalyzerSettings.psd1` in the repo that wants
them. The PowerShell extension picks it up from the workspace root by default.

The Pester extension's publisher (`pspester`) was added to `extensions.allowed` in
`vscode_config/settings.json`. Without it, VS Code blocks the install.

### `Workloads/sql/configuration-local.winget`

`SQLServerDeveloper` is removed. As of 2026-09-14, every public SQL Server 2025 bootstrapper
(`SQL2025-SSEI-StdDev.exe`, `-EntDev`, `-Expr`) is version `17.0.1000.7`. That includes the file
the winget manifest pins and the one behind Microsoft's download page. Microsoft's online
`Manifest_Bootstrap_All.xml` sets `SupportedEngineVersion` to `17.0.1000.9`. The bootstrapper
logs `Current version: '17.0.1000.7', Minimum version: '17.0.1000.9'` and exits `1009` right
after its OS check, with or without winget. Logs are in
`C:\Program Files\Microsoft SQL Server\170\SSEI\LogFiles\`.

Once a newer bootstrapper ships, apply upstream `Workloads\sql\configuration.winget` as-is.

## WSL steps on this machine

Both generations of the flow gate their WSL work on the same signals, and both are satisfied here:

| Signal | DSC snapshot | PowerShell flow | State here |
| --- | --- | --- | --- |
| `vmcompute` service registered | `RebootForVmp` skips, no reboot | `WslComponents` already OK | Registered (WSL2 active) |
| Distro registered | `InstallUbuntu` skips if any distro exists | `WslUbuntu` skips only if an `Ubuntu*` distro exists | Debian, Ubuntu, RHEL-10, docker-desktop |

Re-check both before applying on a *different* machine, where they would fire and the run
**would** reboot.

The "State here" column describes the machine this file was written on. On a machine without an
`Ubuntu*` distro the PowerShell flow's `WslUbuntu` step runs, and upstream's step wipes the other
distro registrations first (see "Audit fixes" below). `apply-ps-flow.ps1` guards against that;
the signed copy and `bootstrap.ps1` do not.

## `.local-run/`

Local tooling and the artifacts of the 2026-09-07 run. Not part of upstream, safe to delete.

| File | What it is |
| --- | --- |
| `apply.ps1` | Elevated apply wrapper for the DSC snapshot, location-independent |
| `apply-ps-flow.ps1` | Stages and runs upstream's PowerShell flow without the RemoteDesktop step, with the `Lxss` guard and optional `-SkipSteps` / `-SkipPackages` / `-KeepNotifications` |
| `capture-state.ps1` | Records the current registry state and regenerates `revert-registry.ps1` for both flows |
| `revert-registry.ps1` | Restores the 23 registry values to their pre-run state of 2026-09-07 |
| `before-state.txt` | What those values were before the run |
| `terminal-settings.json` | Windows Terminal settings.json as it was before the run |
| `apply.log` | Full log of the run (50/50 units applied, exit 0). Untracked: `.gitignore` ignores `*.log` |
| `remove-remotedesktop.patch` | The diff documented above |

Re-run `capture-state.ps1` before any future apply to refresh the revert point. It writes a
fresh timestamped backup directory rather than overwriting the committed one. The committed
revert point predates the theme values, `fDenyTSConnections` and the PowerShell flow's registry
locations, which `capture-state.ps1` records now.

## Review fixes on top of upstream (2026-09-17)

These edits touch upstream files. None of them are in upstream `main`, so they are candidates for
upstream pull requests.

| File | Change |
| --- | --- |
| `src/Workloads/powershell/configuration.winget` | `Read-VSCodeSettings` no longer strips comments with a regex before `ConvertFrom-Json`. The block-comment pattern matched from `/**"` in one glob key to `"**/` in the next and deleted everything in between: `"**/.venv/**": true, "**/node_modules/**": true` became `"**/.venvnode_modules/**": true`. pwsh 7 parses JSONC comments and trailing commas natively. The unit still rewrites `settings.json` through `ConvertTo-Json`, so `configuration-local.winget` keeps it removed. |
| `src/manifest.yml` | The `winforms` build wrote to `tests/winforms/bin` while `run` executed `src\tests\winforms\bin\hello.exe`. Both now use `src/tests/winforms/bin`. |
| `.github/skills/dsc-resource-authoring/SKILL.md` | Removed references to a non-existent `AGENTS.md`. Paths updated from the old `scripts/windows/<id>/` layout to `src/Workloads/<id>/` and `src/manifest.yml`. |
| `SUPPORT.md` | Replaced the untouched Microsoft template placeholders with the actual issue-reporting instructions. |
| `.github/dependabot.yml` | Added a `nuget` entry for the Command Palette project so its packages get vulnerability and version updates. |
| `.gitattributes` | `*.sh` is checked out with LF. Windows checkouts previously produced CRLF bash scripts. |
| `src/tests/wsl-comfort-shell/` | Deleted. Nothing referenced it after the flow was renamed to `comfort-shell` (`src/tests/comfort-shell/`). |
| `src/wsl-comfort/install.ps1`, `readme.md` | The closing message names the profile the script actually creates (`Comfort Shell - <distro>`), and the readme names the real function (`Get-InstalledWslDistros`). |
| `src/future/cmdpal/` | `ExtensionConfig` defaults point at `microsoft/WindowsDeveloperConfig` `main` and `src/manifest.yml` instead of a private personal clone path. The fix-it script path is `Workloads/_common/enable-winget-configure.ps1`; the `scripts/windows/` layout no longer exists. README config example and build path updated. Still open: the DSC summary parser understands only the v0.2 `- resource:` format, so every dscv3 flow shows "No resources found". |

## Audit fixes (2026-09-19)

Found while reviewing the whole fork line by line before running it on a second, hardened machine
(Debian + docker-desktop in WSL, no Ubuntu; Controlled Folder Access on; BitLocker with a startup
PIN). Upstream files are still untouched; everything below lives in `.local-run/`, `.gitignore`
and the fork's own snapshot.

| File | Change |
| --- | --- |
| `.local-run/apply-ps-flow.ps1` | **Guards the `Lxss` key.** Upstream `steps\wsl.ps1` (line 178 in `062a375`) runs `New-Item -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss -Force` without a `Test-Path` check. In the registry provider, `-Force` on an existing key silently deletes its values **and subkeys** (verified on PowerShell 7.6.6 and Windows PowerShell 5.1 with a scratch key), and the subkeys of `Lxss` are the WSL distro registrations. The step runs whenever `wsl --list` shows no `Ubuntu*` distro, so a machine with only Debian or docker-desktop loses those registrations (the VHDX files survive, but the distros have to be re-imported). The staged copy now only creates the key when it is missing. The repo's own helper `steps\_registry.ps1` already has that guard. Candidate for an upstream issue/PR. |
| `.local-run/apply-ps-flow.ps1` | New `-SkipSteps`, `-SkipPackages` and `-KeepNotifications`. Upstream has no skip switch and no dry run; the only supported way to leave a phase out is a missing phase file, which is what `-SkipSteps` produces in the staged copy. `-KeepNotifications` exists because `DoNotDisturb` (`NOC_GLOBAL_SETTING_TOASTS_ENABLED=0`) also hides Defender, Controlled Folder Access and BitLocker toasts. Skipping `wsl` removes the flow's only forced reboot (`shutdown /r /t 0 /f` after 10 s), which matters on a machine that stops at a BitLocker PIN prompt. The summary line now lists every change made to the staged copy. |
| `.gitignore` | `devconfig-log.txt` is now ignored. The old comment claimed `*.log` covered it; it does not, so a transcript with machine name, user name and paths could be committed to this public fork. |
| `windows-dev-config/dev-config-nordp.winget` | The `RebootForVmp` resume command pointed at `dev-config.winget`, which does not exist in this fork, so a post-reboot resume would fail. It now points at `dev-config-nordp.winget`. This is one functional line on top of `remove-remotedesktop.patch`; the snapshot otherwise still equals upstream `b5561d1` minus the RemoteDesktop resource. The two comment lines that mention `dev-config.winget` are upstream text and unchanged. |

Still true after these fixes, and worth knowing before running anything else in this repo:

- The signed copy under `windows-dev-config\` and `src\windows-dev-config\steps\registry-system.ps1`
  both still contain `fDenyTSConnections = 0`. Only `apply-ps-flow.ps1` and the nordp snapshot are
  RDP-free. `bootstrap.ps1` and the README one-liner hard-code `microsoft/WindowsDeveloperConfig`,
  so they always download upstream `main` (with RDP, without the Lxss guard), never this fork.
- `signed-copy-guard` only runs on pull requests and never calls `Get-AuthenticodeSignature`; it is
  a drift reporter, not a signature check.
- `Workloads\powershell\install.ps1` and `Workloads\sql\install.ps1` hard-code
  `configuration.winget`. The `configuration-local.winget` variants are only used when passed to
  `winget configure` by hand.
- The "State here" remarks above (Ubuntu registered, workloads applied 2026-09-14, revert point of
  2026-09-07) describe the first machine. Run `capture-state.ps1` on any other machine before
  applying; the committed `revert-registry.ps1` is not valid there.
