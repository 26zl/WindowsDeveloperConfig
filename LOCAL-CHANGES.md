# Local changes

This is a vendored copy of [microsoft/WindowsDeveloperConfig](https://github.com/microsoft/WindowsDeveloperConfig),
cloned at upstream commit `b5561d1`. Everything is upstream and unmodified **except** the
files described below: `dev-config-nordp.winget` and two `configuration-local.winget` copies.

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

### Re-applying after an upstream update

`dev-config-nordp.winget` is a snapshot, not a live overlay — pulling upstream will **not**
update it. After `git pull`, regenerate it:

```powershell
cd windows-dev-config
git apply ..\.local-run\remove-remotedesktop.patch --directory=windows-dev-config 2>$null
# if the patch no longer applies cleanly, re-cut it by hand and confirm:
Select-String -Path .\dev-config-nordp.winget -Pattern 'fDenyTSConnections'   # must return nothing
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
| `apply.log` | Full log of the run (50/50 units applied, exit 0) |
| `remove-remotedesktop.patch` | The diff documented above |

Re-run `capture-state.ps1` before any future apply to refresh the revert point — it writes a
fresh timestamped backup directory rather than overwriting this one.
