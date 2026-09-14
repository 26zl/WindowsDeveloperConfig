<#
.SYNOPSIS
  System-level developer settings: long path support.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-RegistrySystemPhase {
    $tweaks = @(
        @{ Name = 'LongPaths';     KeyPath = 'HKLM\SYSTEM\CurrentControlSet\Control\FileSystem';              ValueName = 'LongPathsEnabled';               Value = 1; Description = 'Enable Win32 long path support' }
    )

    # ArgumentList binds each tweak's values at call time instead of closure capture.
    $steps = foreach ($tweak in $tweaks) {
        New-DevConfigStep -Name $tweak.Name -Description $tweak.Description `
            -Check { param($KeyPath, $ValueName, $Value) Test-DevConfigRegistryValue -KeyPath $KeyPath -ValueName $ValueName -Value $Value } `
            -Apply { param($KeyPath, $ValueName, $Value) Set-DevConfigRegistryValue -KeyPath $KeyPath -ValueName $ValueName -Value $Value } `
            -ArgumentList @($tweak.KeyPath, $tweak.ValueName, $tweak.Value)
    }

    Invoke-DevConfigSteps -Steps $steps
}
