---
name: dsc-resource-authoring
description: >
  Helps discover DSC resources available via dsc.exe, author new
  configuration.winget files for this repository, and debug existing DSC
  configurations. Use this skill when the user asks to add a new flow,
  pick a DSC resource, write or fix a configuration.winget, or debug a
  winget configure error.
---

# DSC Resource Authoring Skill

This skill guides you through three related tasks that all revolve around
`dsc.exe` (DSC v3) and `winget configure`:

1. **Discover** — enumerate and inspect resources available on the machine.
2. **Author** — compose a valid `configuration.winget` file that follows
   the rules below.
3. **Debug** — validate and diagnose an existing configuration.

Source lives under `src/`: flows in `src/Workloads/<id>/`, the flow list in
`src/manifest.yml`. This skill turns the repository's rules into concrete `dsc` commands.

---

## Phase 1 — Discover Available Resources

### List all resources

```powershell
dsc resource list -o json | ConvertFrom-Json
```

Using `-o json` gives structured output that is easy to filter and inspect.
Key fields on each object:
- **type** — the resource type string you put in the `type:` field of a `.winget`.
- **kind** — `Resource`, `Adapter`, or `Group`.
- **version** — the resource module version.

### Filter by name or adapter

```powershell
# Find WinGet-related resources
dsc resource list -o json | ConvertFrom-Json | Where-Object { $_.type -like '*WinGet*' }

# Extract just the type strings for quick scanning
dsc resource list -o json | ConvertFrom-Json | Select-Object -ExpandProperty type | Sort-Object
```

For a new language/tool flow the two relevant types are:
- **`Microsoft.WinGet/Package`** — dscv3 native resource (preferred, see the schema table below).
- **`Microsoft.WinGet.DSC/WinGetPackage`** — v0.2 PowerShell resource (fallback
  only when `PSDscResources/Script` is also needed).

### Inspect a resource's schema

```powershell
dsc resource schema --resource Microsoft.WinGet/Package -o json | ConvertFrom-Json
```

This emits the JSON Schema for the resource as a structured object. Drill into
specific properties to confirm names and types — e.g. confirm that
`acceptAgreements` (required on every package resource) is present:

```powershell
$schema = dsc resource schema --resource Microsoft.WinGet/Package -o json | ConvertFrom-Json
$schema.properties.PSObject.Properties | Select-Object Name
```

### Find the exact winget package id

```powershell
# Search the winget community repo
winget search <keyword>

# Confirm the id exists and check available versions
winget show <Publisher.Product>
```

Always use a **versioned** id (e.g. `Python.Python.3.14`),
never a bare id (e.g. `Python.Python`).

---

## Phase 2 — Author a configuration.winget

### Ask the user what they want to install

Use `ask_user` to confirm:
1. The package(s) to install and the preferred minor version.
2. Whether a post-install PowerShell step is needed (if yes → v0.2 with
   `PSDscResources/Script`; otherwise → dscv3, which is strongly preferred).
3. Whether there are install-order dependencies between packages.

### Choose the schema version

| Need | Schema | Resource |
|---|---|---|
| Pure package install | dscv3 | `Microsoft.WinGet/Package` |
| Simple fire-and-forget command | dscv3 | `Microsoft.DSC.Transitional/RunCommandOnSet` |
| Idempotent PowerShell 7 script (get/test/set) | dscv3 | `Microsoft.DSC.Transitional/PowerShellScript` |
| Idempotent Windows PowerShell 5.1 script (get/test/set) | dscv3 | `Microsoft.DSC.Transitional/WindowsPowerShellScript` |
| Requires `PSDscResources/Script` specifically | v0.2 | `Microsoft.WinGet.DSC/WinGetPackage` + `PSDscResources/Script` |

Prefer the native dscv3 `Microsoft.DSC.Transitional/*` resources over v0.2 + `PSDscResources/Script`
whenever possible — they keep the dscv3 document shape and do not require dropping the schema version.
Only fall back to v0.2 if the CI runner cannot resolve the Transitional resources.

### dscv3 template (preferred)

```yaml
# yaml-language-server: $schema=https://raw.githubusercontent.com/PowerShell/DSC/main/schemas/2023/08/config/document.json
#
# Canonical invocation:
#   winget configure --file configuration.winget --disable-interactivity --accept-configuration-agreements
#
# Package id tracks <Publisher.Product> minor release line.
# Bump the id when the current minor goes EOL or the manifest 404s.

$schema: https://raw.githubusercontent.com/PowerShell/DSC/main/schemas/2023/08/config/document.json
metadata:
  winget:
    processor: dscv3
resources:
  - name: <PascalName>
    type: Microsoft.WinGet/Package
    metadata:
      securityContext: elevated
    properties:
      id: <Publisher.Product.MajorMinor>
      source: winget
      acceptAgreements: true
```

### dscv3 — RunCommandOnSet (fire-and-forget, runs only on Set)

Use when you need to run a single command or script file as a post-step and
idempotency checking is handled externally (or not required). The resource only
runs its command during a `set` operation; `get` and `test` are no-ops.

```yaml
- name: RunMySetupCommand
  type: Microsoft.DSC.Transitional/RunCommandOnSet
  properties:
    executable: pwsh
    arguments:
      - -NoProfile
      - -NoLogo
      - -File
      - C:\setup\configure-something.ps1
```

To run an inline snippet instead of a script file, use `-Command`:

```yaml
- name: InstallPSModule
  type: Microsoft.DSC.Transitional/RunCommandOnSet
  properties:
    executable: pwsh
    arguments:
      - -NoProfile
      - -NoLogo
      - -Command
      - if (-not (Get-Module -ListAvailable MyModule)) { Install-Module MyModule -Force }
```

### dscv3 — PowerShellScript (idempotent, PowerShell 7)

Use when you need full get/test/set idempotency in PowerShell 7. DSC calls
`testScript` first; if it returns `$true`, `setScript` is skipped.
`_inDesiredState: true` in the output signals "no change needed".

```yaml
- name: ConfigureMyTool
  type: Microsoft.DSC.Transitional/PowerShellScript
  properties:
    getScript: |
      $configured = Test-Path "$env:APPDATA\MyTool\config.json"
      return @{ configured = $configured }
    testScript: |
      return Test-Path "$env:APPDATA\MyTool\config.json"
    setScript: |
      New-Item -ItemType Directory -Force "$env:APPDATA\MyTool" | Out-Null
      '{"theme":"dark"}' | Set-Content "$env:APPDATA\MyTool\config.json"
```

### dscv3 — WindowsPowerShellScript (idempotent, Windows PowerShell 5.1)

Identical schema to `PowerShellScript` but runs in `powershell.exe` (5.1).
Use when the script relies on a module or API only available in Windows PowerShell.

```yaml
- name: ConfigureWithPS51
  type: Microsoft.DSC.Transitional/WindowsPowerShellScript
  properties:
    getScript: |
      return @{ Result = (Get-ItemPropertyValue HKCU:\Software\MyApp -Name Setting -EA SilentlyContinue) }
    testScript: |
      $val = Get-ItemPropertyValue HKCU:\Software\MyApp -Name Setting -EA SilentlyContinue
      return $val -eq 1
    setScript: |
      New-Item -Path HKCU:\Software\MyApp -Force | Out-Null
      Set-ItemProperty -Path HKCU:\Software\MyApp -Name Setting -Value 1
```

Key rules to enforce:
- `acceptAgreements: true` **must** appear on every `Microsoft.WinGet/Package`
  resource. Do not rely on CLI-level flags for consent.
- `$schema` URL must be
  `https://raw.githubusercontent.com/PowerShell/DSC/main/schemas/2023/08/config/document.json`
  (not an `aka.ms` short link).
- Package id must be versioned to minor level.

### v0.2 template (only when `PSDscResources/Script` is needed)

```yaml
# yaml-language-server: $schema=https://aka.ms/configuration-dsc-schema/0.2
#
# Canonical invocation (agreement flags required because v0.2 lacks acceptAgreements property):
#   winget configure --file configuration.winget --disable-interactivity \
#     --accept-configuration-agreements --accept-package-agreements

properties:
  configurationVersion: 0.2.0
  resources:
    - resource: Microsoft.WinGet.DSC/WinGetPackage
      id: Install<PascalName>
      directives:
        description: Install <Name>
        allowPrerelease: false
      settings:
        id: <Publisher.Product.MajorMinor>
        source: winget

    - resource: PSDscResources/Script
      id: Configure<PascalName>
      dependsOn: [Install<PascalName>]
      settings:
        GetScript:  |
          return @{ Result = '' }
        TestScript: |
          # return $true if already in desired state
        SetScript:  |
          # bring the system into desired state
```

### Write the file

Place it at `src/Workloads/<id>/configuration.winget`. After writing, verify
it parses cleanly:

```powershell
python3 -c "import yaml; yaml.safe_load(open('src/Workloads/<id>/configuration.winget'))"
```

---

## Phase 3 — Debug an Existing Configuration

### Validate YAML syntax

```powershell
python3 -c "import yaml; yaml.safe_load(open('<path-to-config>'))"
```

### Dry-run the configuration

```powershell
# Test what-if (does not apply changes); JSON makes pass/fail easy to inspect
dsc config test --file <path-to-config> -o json | ConvertFrom-Json
```

### Check resource get state

```powershell
# Read the current state of a specific resource
dsc resource get --resource Microsoft.WinGet/Package -o json `
    --input '{"id":"<Publisher.Product.MajorMinor>"}' | ConvertFrom-Json
```

### Apply with verbose output

```powershell
winget configure --file <path-to-config> --disable-interactivity --accept-configuration-agreements --verbose-logs
```

Logs are written to `%LOCALAPPDATA%\Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\DiagOutputDir\`.

### Common failure patterns

| Symptom | Likely cause | Fix |
|---|---|---|
| `acceptAgreements` missing/false | Consent not passed | Add `acceptAgreements: true` to every `Microsoft.WinGet/Package` resource |
| Package id not found | Unversioned or wrong id | Run `winget search` to confirm the exact id; use minor-versioned form |
| `$schema` URL rejected | Wrong schema URL | Use `raw.githubusercontent.com/PowerShell/DSC/...` URL, not `aka.ms` |
| Interactive prompt during CI | `--disable-interactivity` missing | `apply-configuration.ps1` adds this; verify it is invoked via the shim |
| `PSDscResources/Script` fails on dscv3 | Wrong schema version | Switch to v0.2 for any config that needs `Script` resources |

---

## Checklist Before Committing a New Flow

Run the static checks (the same ones `src/docs/development.md` lists):

```powershell
# 1. YAML parses
python3 -c "import yaml; yaml.safe_load(open('src/Workloads/<id>/configuration.winget'))"

# 2. src/manifest.yml is valid
python3 - <<'PY'
import yaml
doc = yaml.safe_load(open("src/manifest.yml"))
for flow in doc["flows"]:
    for os_name in flow["os"]:
        spec = flow.get(os_name) or {}
        missing = [k for k in ("install", "run", "expected") if not spec.get(k)]
        assert not missing, f"{flow['id']}/{os_name} missing {missing}"
        print("OK:", flow["id"], os_name)
PY

# 3. All .ps1 files parse
Get-ChildItem -Recurse -Filter *.ps1 | ForEach-Object {
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $_.FullName, [ref]$null, [ref]$errs)
    if ($errs) { Write-Error "$($_.FullName): $errs" } else { "OK: $($_.Name)" }
}
```
