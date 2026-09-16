# Applies the RDP-free copy of dev-config.winget.
# Must run ELEVATED. Location-independent: resolves paths from its own directory.
$repo = Split-Path -Parent $PSScriptRoot
$cfg  = Join-Path $repo 'windows-dev-config\dev-config-nordp.winget'
$log  = Join-Path $PSScriptRoot ("apply-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

if (-not (Test-Path -LiteralPath $cfg)) { throw "Config not found: $cfg" }

$elevated = [Security.Principal.WindowsPrincipal]::new(
              [Security.Principal.WindowsIdentity]::GetCurrent()
            ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $elevated) { throw "Not elevated. Re-run this script from an admin PowerShell 7." }

"=== Started $(Get-Date -Format o) ===" | Set-Content -Path $log -Encoding UTF8
"Config: $cfg" | Add-Content -Path $log
winget configure --file $cfg --accept-configuration-agreements --disable-interactivity 2>&1 |
  ForEach-Object { $_ | Out-String -Width 200 } | Add-Content -Path $log
"=== Finished $(Get-Date -Format o) exit=$LASTEXITCODE ===" | Add-Content -Path $log
"Log written to: $log"
