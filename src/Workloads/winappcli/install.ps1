<#
.SYNOPSIS
  Apply the WinAppCLI winget DSC configuration on Windows.

.DESCRIPTION
  This script is a thin CI/dev shim. The core artifact for the WinAppCLI flow
  is `configuration.winget` in this directory - a dscv3 winget DSC config
  that verifies the supported Windows version, enables Developer Mode, and
  installs the .NET 10 SDK and Windows App Development CLI.

  The shim applies the configuration with the shared retry helper, refreshes
  PATH, verifies `dotnet` and `winapp`, and emits `INSTALL_OK: winappcli` for
  the test harness.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

& (Join-Path $PSScriptRoot '..\_common\apply-configuration.ps1') `
    -Id              'winappcli' `
    -ConfigFile      (Join-Path $PSScriptRoot 'configuration.winget') `
    -RequireCommands @('dotnet', 'winapp')
