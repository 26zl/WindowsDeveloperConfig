# Local changes

This is a fork of [microsoft/WindowsDeveloperConfig](https://github.com/microsoft/WindowsDeveloperConfig),
kept in sync with upstream `main` (last merged: `af48162`, 2026-10-10). Everything is upstream and
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
`steps/*.ps1` in `ff7a538` (2026-09-16). Since #103 (merged here with `bf74ae3`) the signed flow
refuses to start unless every `.ps1` has a valid Microsoft signature and the folder it runs from
is owned by Administrators/SYSTEM and writable by no one else, so a modified copy has to be the
unsigned one under `src/` run with `-AllowUnsigned`, which is exactly how upstream's README says
to customize it. With `-AllowUnsigned` both checks are skipped, so the staged copy under
`%LOCALAPPDATA%` still runs. Since #125 (`0dd0cbc`, merged here 2026-10-02) the flow is a workload
engine: `dev-config.ps1 -Workload <name>` reads its phase list from `workloads\<name>.ps1` (default
`devconfig`), `steps\packages.ps1` is a shared catalog that the workload selects from by name, and
a phase file that is missing is an error rather than a skip.

`apply-ps-flow.ps1` does that without touching the checkout:

1. Copies `src\windows-dev-config\dev-config.ps1`, `steps\` and `workloads\` to
   `%LOCALAPPDATA%\CalmOS-nordp`, a location that survives the reboot the flow may need.
2. Deletes the `RemoteDesktop` entry from the staged `steps\registry-system.ps1`. It fails if it
   finds anything other than exactly one such entry, or if `fDenyTSConnections` is still referenced
   anywhere under `steps\` or `workloads\`.
3. Optionally trims the staged copy: `-SkipSteps` removes the phase's entry from the staged
   `workloads\devconfig.ps1`, `-SkipPackages` looks each winget ID up in the staged catalog and
   removes the catalog name from the workload's package list, `-SkipTweaks` removes single registry
   tweaks by name, and `-KeepNotifications` is shorthand for `-SkipTweaks DoNotDisturb`. Every
   removal has to match exactly one entry, otherwise the script stops. Entries are removed as whole
   `@{ ... }` blocks found by counting braces, which handles the one-line layout, the multi-line
   layout from #108 and the nested workload blocks from #125.
4. Runs `pwsh -NoProfile -File <staged>\dev-config.ps1 -AllowUnsigned`, which is upstream's
   default workload (`devconfig`) and action (`Full`). `Partial` (what `setup-standard.ps1` runs
   since #108) would also leave out Sudo, Developer Mode, the Edge policies and most taskbar tweaks,
   so the fork keeps `Full` minus RemoteDesktop. The flow requests UAC by itself. `-NoLaunch`
   stages and prints the command instead of running it.

The `Lxss` guard the script carried until 2026-09-26 is gone: since #108 (`06200f0`) upstream
creates the key through `Set-DevConfigRegistryValue`, which checks `Test-Path` first (see "Audit
fixes" below).

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
- counts a package as done only when it is installed **and** current, so it upgrades every
  package the `devconfig` workload lists;
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
`Ubuntu*` distro the PowerShell flow's `WslUbuntu` step runs. Until #108 that step wiped the other
distro registrations first (see "Audit fixes" below); since `06200f0` it creates the `Lxss` key
only when it is missing, in `src/`, in the signed copy and in what `bootstrap.ps1` downloads.

## `.local-run/`

Local tooling and the artifacts of the 2026-09-07 run. Not part of upstream, safe to delete.

| File | What it is |
| --- | --- |
| `apply.ps1` | Elevated apply wrapper for the DSC snapshot, location-independent |
| `apply-ps-flow.ps1` | Stages and runs upstream's PowerShell flow without the RemoteDesktop step, with optional `-SkipSteps` / `-SkipPackages` / `-SkipTweaks` / `-KeepNotifications` |
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

These edits touch upstream files. Status as of 2026-10-02: the manifest and wsl-comfort rows were
merged upstream as #119 and #120 (2026-09-29), so they are now identical to upstream; the
`configuration.winget` row is open as #118 (with a comment-only-file fix on top of the fork's
version); the SKILL.md/cmdpal, SUPPORT.md and `wsl-comfort-shell` rows are drafts in
`pull-request-fremtidig/`; dependabot and `.gitattributes` stay fork-only.

| File | Change |
| --- | --- |
| `src/Workloads/powershell/configuration.winget` | `Read-VSCodeSettings` no longer strips comments with a regex before `ConvertFrom-Json`. The block-comment pattern matched from `/**"` in one glob key to `"**/` in the next and deleted everything in between: `"**/.venv/**": true, "**/node_modules/**": true` became `"**/.venvnode_modules/**": true`. pwsh 7 parses JSONC comments and trailing commas natively. The unit still rewrites `settings.json` through `ConvertTo-Json`, so `configuration-local.winget` keeps it removed. Open upstream as #118, where a file holding only comments (which parses to `$null`) is also mapped back to an empty table; the fork's copy does not have that extra guard yet. |
| `src/manifest.yml` | The `winforms` build wrote to `tests/winforms/bin` while `run` executed `src\tests\winforms\bin\hello.exe`. Both now use `src/tests/winforms/bin`. Merged upstream as #119. |
| `.github/skills/dsc-resource-authoring/SKILL.md` | Removed references to a non-existent `AGENTS.md`. Paths updated from the old `scripts/windows/<id>/` layout to `src/Workloads/<id>/` and `src/manifest.yml`. Draft 04. |
| `SUPPORT.md` | Replaced the untouched Microsoft template placeholders with the actual issue-reporting instructions. Draft 11. |
| `.github/dependabot.yml` | Added a `nuget` entry for the Command Palette project so its packages get vulnerability and version updates. |
| `.gitattributes` | `*.sh` is checked out with LF. Windows checkouts previously produced CRLF bash scripts. |
| `src/tests/wsl-comfort-shell/` | Deleted. Nothing referenced it after the flow was renamed to `comfort-shell` (`src/tests/comfort-shell/`). Draft 12. |
| `src/wsl-comfort/install.ps1`, `readme.md` | The closing message names the profile the script actually creates (`Comfort Shell - <distro>`), and the readme names the real function (`Get-InstalledWslDistros`). Merged upstream as #120. |
| `src/future/cmdpal/` | `ExtensionConfig` defaults point at `microsoft/WindowsDeveloperConfig` `main` and `src/manifest.yml` instead of a private personal clone path. The fix-it script path is `Workloads/_common/enable-winget-configure.ps1`; the `scripts/windows/` layout no longer exists. README config example and build path updated. Upstream #104 (merged 2026-10-07) changed the `LocalPath` default to `C:\WindowsDeveloperConfig` and replaced the "Known gap" README paragraph (the extension now runs `windows.install` directly); both taken from upstream in the 2026-10-09 merge, the other defaults above are still the fork's. Still open: the DSC summary parser understands only the v0.2 `- resource:` format, so every dscv3 flow shows "No resources found". |

## Audit fixes (2026-09-19)

Found while reviewing the whole fork line by line before running it on a second, hardened machine
(Debian + docker-desktop in WSL, no Ubuntu; Controlled Folder Access on; BitLocker with a startup
PIN). Upstream files are still untouched; everything below lives in `.local-run/`, `.gitignore`
and the fork's own snapshot.

| File | Change |
| --- | --- |
| `.local-run/apply-ps-flow.ps1` | **Guards the `Lxss` key.** Upstream `steps\wsl.ps1` (line 178 in `062a375`) runs `New-Item -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss -Force` without a `Test-Path` check. In the registry provider, `-Force` on an existing key silently deletes its values **and subkeys** (verified on PowerShell 7.6.6 and Windows PowerShell 5.1 with a scratch key), and the subkeys of `Lxss` are the WSL distro registrations. The step runs whenever `wsl --list` shows no `Ubuntu*` distro, so a machine with only Debian or docker-desktop loses those registrations (the VHDX files survive, but the distros have to be re-imported). The staged copy now only creates the key when it is missing. The repo's own helper `steps\_registry.ps1` already has that guard. Candidate for an upstream issue/PR. **Resolved upstream in #108** (`06200f0`, merged here 2026-09-26): `wsl.ps1` now sets `OOBEComplete` through `Set-DevConfigRegistryValue`, which only creates the key when it is missing. The guard was removed from `apply-ps-flow.ps1` at that sync. |
| `.local-run/apply-ps-flow.ps1` | New `-SkipSteps`, `-SkipPackages` and `-KeepNotifications`. Upstream has no skip switch and no dry run; the only supported way to leave a phase out is a missing phase file, which is what `-SkipSteps` produces in the staged copy. `-KeepNotifications` exists because `DoNotDisturb` (`NOC_GLOBAL_SETTING_TOASTS_ENABLED=0`) also hides Defender, Controlled Folder Access and BitLocker toasts. Skipping `wsl` removes the flow's only forced reboot (`shutdown /r /t 0 /f` after 10 s), which matters on a machine that stops at a BitLocker PIN prompt. The summary line now lists every change made to the staged copy. Since #125 (sync of 2026-10-02) a missing phase file is an error, so `-SkipSteps` removes the phase's entry from the staged `workloads\devconfig.ps1` instead, and `-SkipPackages` maps the winget ID to the catalog name the workload lists. |
| `.local-run/apply-ps-flow.ps1` | New `-SkipTweaks`. Found on the first real run on the second machine (Windows 11 25H2, build 26200): `WidgetServiceOff` fails with "Attempted to perform an unauthorized operation" although Administrators have FullControl on `HKLM\SOFTWARE\Policies\Microsoft\Dsh`. `UCPD.sys` (User Choice Protection Driver) is running and denies PowerShell the write. The registry tweaks are not best-effort upstream, so that one failure stopped the run before the Edge, fonts and Terminal phases. With `-SkipTweaks WidgetServiceOff` the run completes (exit 0). **Resolved upstream in #108**, after #109 reported the same failure: `WidgetServiceOff` is `BestEffort = $true`, so the run continues and the step is counted as flagged. `-SkipTweaks` stays for tweaks one does not want; since the sync to `06200f0` it removes whole `@{ ... }` blocks, because #108 turned every tweak and package entry from one line into a block. |
| `.gitignore` | `devconfig-log.txt` is now ignored. The old comment claimed `*.log` covered it; it does not, so a transcript with machine name, user name and paths could be committed to this public fork. |
| `windows-dev-config/dev-config-nordp.winget` | The `RebootForVmp` resume command pointed at `dev-config.winget`, which does not exist in this fork, so a post-reboot resume would fail. It now points at `dev-config-nordp.winget`. This is one functional line on top of `remove-remotedesktop.patch`; the snapshot otherwise still equals upstream `b5561d1` minus the RemoteDesktop resource. The two comment lines that mention `dev-config.winget` are upstream text and unchanged. |

Still true after these fixes, and worth knowing before running anything else in this repo:

- The signed copy under `windows-dev-config\` and `src\windows-dev-config\steps\registry-system.ps1`
  both still contain `fDenyTSConnections = 0`. Only `apply-ps-flow.ps1` and the nordp snapshot are
  RDP-free. `bootstrap.ps1` and the README one-liners hard-code `microsoft/WindowsDeveloperConfig`,
  so they always download upstream `main`, never this fork. Since #115 the README one-liners are
  `irm https://aka.ms/devconfig/{standard,full}/setup.ps1 | iex`, which resolve to the signed
  `windows-dev-config/setup-standard.ps1` and `setup-full.ps1`; `standard` runs `-Action Partial`,
  which leaves RemoteDesktop, Sudo and Developer Mode alone, `full` runs `-Action Full` with RDP.
- `signed-copy-guard` only runs on pull requests and never calls `Get-AuthenticodeSignature`; it is
  a drift reporter, not a signature check.
- Since the sync to `bf74ae3`, `.gitattributes` checks out every `.ps1` under `Workloads\` and
  `wsl-comfort\` byte for byte (`-text`). Those blobs were committed with LF line endings, so a
  fresh clone or ZIP of this fork, or of upstream `main`, gets them without CRLF and
  `Get-AuthenticodeSignature` reports `NotSigned` for all 18. Before, they checked out with CRLF
  and 12 of the 17 under `Workloads\` were `Valid`; the other 5 (`php`, `python`, `typescript`,
  `winforms` and `winui` `install.ps1`) were already `HashMismatch`. An existing checkout keeps
  its CRLF files until git rewrites them. Only `windows-dev-config\` (32 files at `231c59b`,
  re-committed as raw bytes in #107 and re-signed in #110, #112, #114, #126, #130, #132 and #134) is
  `Valid` in a fresh clone, plus the new `Workloads\winui\setup.ps1` from #125. Re-checked
  2026-10-03 on a `git archive` of `231c59b`: `Workloads\` is 1 `Valid`, 16 `NotSigned` and 1
  `HashMismatch` (the freshly re-signed `winui\install.ps1`, committed with CRLF and a signature
  block that still does not verify), `wsl-comfort\` is 1 `NotSigned`, and `check-signed-drift.ps1`
  reports `winappcli` missing and `wsl-comfort\comfort-shell-bootstrap.sh`, `install.ps1` and
  `readme.md` drifted (the last two because #120 landed in `src/` without a new sign run).
  Reported upstream as #137 (2026-10-03); upstream's #150 (2026-10-07, "Refresh signed release
  copies and restore valid signatures", closes #137) re-signed everything and #145 removed
  `Workloads\winui\install.ps1`. Re-checked 2026-10-07 on a `git archive` of `182cd11`:
  `windows-dev-config\` 32 `Valid`, `Workloads\` 14 `Valid` and 4 `HashMismatch` (`php`, `python`,
  `typescript`, `winforms`: freshly re-signed, CRLF, body matching `src/`, still failing in pwsh
  7.6.6 and Windows PowerShell 5.1), `wsl-comfort\` 1 `Valid`, drift checker all `ok`, `winappcli`
  copy present. So a fresh clone of this fork now verifies except for those four shims.
  Those four were the locale-dependent case (em dash in a BOM-less UTF-8 file, hashed as
  Windows-1252 by the signer, verified as UTF-8 on a machine with code page 65001); reported as a
  comment on #137 on 2026-10-07 and fixed upstream the same night by #154 (hyphen instead of the
  dash), #156 (release signature verification) and #157 (re-sign). On a `git archive` of `0be0f2a`
  (2026-10-09) every `.ps1` under the three roots is `Valid`: 32, 43 and 1. The drift checker now
  lists the `dotnet`/`php` workload files from #158/#162 as not yet mirrored, which is just the
  next sign cycle. On `af48162` (2026-10-10, after #165/#172/#173/#174) everything is `Valid`
  (39, 43 and 1) and the drift checker reports 101 `ok`, nothing drifted or missing.
- `Workloads\powershell\install.ps1` and `Workloads\sql\install.ps1` hard-code
  `configuration.winget`. The `configuration-local.winget` variants are only used when passed to
  `winget configure` by hand.
- The "State here" remarks above (Ubuntu registered, workloads applied 2026-09-14, revert point of
  2026-09-07) describe the first machine. Run `capture-state.ps1` on any other machine before
  applying; the committed `revert-registry.ps1` is not valid there.
