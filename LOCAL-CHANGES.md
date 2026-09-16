# Local changes

This is a vendored copy of [microsoft/WindowsDeveloperConfig](https://github.com/microsoft/WindowsDeveloperConfig),
cloned at upstream commit `b5561d1`. Everything is upstream and unmodified **except** the
files described below (`dev-config-nordp.winget`, two `configuration-local.winget` copies) and the
review fixes listed at the end.

## `windows-dev-config/dev-config-nordp.winget`

A copy of upstream `dev-config.winget` with the `RemoteDesktop` resource removed
(12 lines; see `.local-run/remove-remotedesktop.patch`). The original
`dev-config.winget` is left untouched alongside it for reference and diffing.

### Why

The upstream resource sets `fDenyTSConnections = 0`, and its description reads
*"Enable Remote Desktop (firewall rule still needs separate enable)"*. That assumption does
not hold on this machine: the **Remote Desktop firewall rule is already enabled**, so
applying the resource takes the box from "RDP blocked" straight to "RDP listening and
reachable" in a single step — with no second gate.

Verify the current state with:

```powershell
Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections
# 1 = RDP blocked (desired here)   0 = RDP enabled
Get-NetFirewallRule -DisplayGroup 'Remote Desktop' | Select-Object Name, Enabled
```

### Applying

Run from an **elevated** PowerShell 7:

```powershell
.\.local-run\apply.ps1
```

The script resolves its own paths, refuses to run unelevated, and writes a timestamped log
next to itself. Or invoke winget directly:

```powershell
winget configure --file .\windows-dev-config\dev-config-nordp.winget `
  --accept-configuration-agreements --disable-interactivity
```

### Upstream status

`dev-config-nordp.winget` is a snapshot of `b5561d1`, not a live overlay. Upstream removed
`dev-config.winget` and `install.ps1` in `ff7a538` (2026-09-16) and replaced them with a
PowerShell flow: `windows-dev-config/bootstrap.ps1`, `dev-config.ps1` and `steps/*.ps1`. No newer
upstream `dev-config.winget` will appear to regenerate this copy from.

The replacement flow still enables Remote Desktop: `steps/registry-system.ps1` carries a
`RemoteDesktop` entry that sets `fDenyTSConnections = 0`. Delete that entry before running it on
this machine; upstream's `windows-dev-config/README.md` documents the same customization.

`.local-run/remove-remotedesktop.patch` records the change against `b5561d1`. It was cut with plain
`diff -u`, so `git apply` needs `-p0` and a fresh copy of the upstream file. From the repo root:

```powershell
Copy-Item .\windows-dev-config\dev-config.winget .\windows-dev-config\dev-config-nordp.winget -Force
git apply -p0 --ignore-whitespace --directory=windows-dev-config .\.local-run\remove-remotedesktop.patch
Select-String -Path .\windows-dev-config\dev-config-nordp.winget -Pattern 'fDenyTSConnections'   # must return nothing
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
  `"**/.venv/**"` and the next `"**/`, swallowing real settings;
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

## No reboot on this machine

Two upstream resources look alarming but are self-skipping here:

| Resource | Gate | Why it skips |
| --- | --- | --- |
| `RebootForVmp` | `testScript` returns true if the `vmcompute` service exists | WSL2 is already active, so the service is registered — **no reboot is triggered** |
| `InstallUbuntu` | `testScript` returns true if any WSL distro is installed | Debian, RHEL-10 and docker-desktop are present — Ubuntu is not installed and the default distro is not changed |

Re-check both before applying on a *different* machine, where they would fire and the run
**would** reboot.

## `.local-run/`

Artifacts from the 2026-09-07 run — not part of upstream, safe to delete.

| File | What it is |
| --- | --- |
| `apply.ps1` | Elevated apply wrapper, location-independent |
| `capture-state.ps1` | Records current registry state and regenerates `revert-registry.ps1` |
| `revert-registry.ps1` | Restores the 23 registry values to their pre-run state |
| `before-state.txt` | What those values were before the run |
| `terminal-settings.json` | Windows Terminal settings.json as it was before the run |
| `apply.log` | Full log of the run (50/50 units applied, exit 0). Untracked: `.gitignore` ignores `*.log` |
| `remove-remotedesktop.patch` | The diff documented above |

Re-run `capture-state.ps1` before any future apply to refresh the revert point — it writes a
fresh timestamped backup directory rather than overwriting this one.

`capture-state.ps1` does not record the two `Themes\Personalize` values (`AppsUseLightTheme`,
`SystemUsesLightTheme`) that the `darkTheme` unit sets. Add them to `$targets` before the next run
if the theme should be part of the revert point.

## Review fixes on top of upstream (2026-09-17)

These edits touch upstream files. None of them are in `ff7a538`, so they are candidates for
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
