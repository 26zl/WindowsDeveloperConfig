<#
.SYNOPSIS
  Taskbar and Start registry tweaks.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-RegistryTaskbarSearchPhase {
    $advanced = 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'

    $tweaks = @(
        @{ Name = 'EndTask';                KeyPath = "$advanced\TaskbarDeveloperSettings";                                   ValueName = 'TaskbarEndTask';                      Value = 1; Description = 'Enable "End Task" on right-click of taskbar icons' }
        @{ Name = 'StartRecommendations';   KeyPath = $advanced;                                                              ValueName = 'Start_IrisRecommendations';           Value = 0; Description = 'Disable Start menu recommendations' }
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
