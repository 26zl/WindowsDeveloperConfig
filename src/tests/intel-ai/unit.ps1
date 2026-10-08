$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\_harness\assertions.ps1')
. (Join-Path $PSScriptRoot '..\..\Workloads\_common\direct-setup.ps1')
. (Join-Path $PSScriptRoot '..\..\Workloads\_common\ai-report.ps1')

$catalog = Get-AiCatalog
Assert-Equal $catalog.Components.IntelOpenVino.Architectures[0] 'X64' 'OpenVINO flow should be native Windows x64 only'
Assert-Equal $catalog.Components.IntelOneApi.PackageId 'Intel.OneAPI.Toolkit' 'oneAPI should use the current unified WinGet package'
Assert-Equal $catalog.Components.IntelOneApi.Version '2026.0.0.193' 'oneAPI metadata should record the qualified stable version'
Assert-True ($catalog.Components.IntelOpenVino.Packages -contains 'openvino==2026.3.1') 'OpenVINO runtime should be exactly pinned'
$gpuPlan = Resolve-IntelAiPlan -Architecture X64 -Device Auto -Profile Full -IntelGpuPresent $true
Assert-Equal $gpuPlan.Device 'GPU' 'Intel Auto should select a detected GPU'
Assert-True $gpuPlan.InstallOpenVino 'Full profile should install OpenVINO'
Assert-True $gpuPlan.InstallOneApi 'Full profile should install oneAPI'
$npuPlan = Resolve-IntelAiPlan -Architecture X64 -Device Auto -Profile OpenVINO -IntelGpuPresent $true -IntelNpuPresent $true
Assert-Equal $npuPlan.Device 'NPU' 'Intel Auto should prefer an available NPU for OpenVINO'
foreach ($allowedDevice in @('Auto', 'GPU')) {
    $syclPlan = Resolve-IntelAiPlan -Architecture X64 -Device $allowedDevice -Profile SYCL -IntelGpuPresent $true -IntelNpuPresent $true
    Assert-Equal $syclPlan.Device 'GPU' 'SYCL-only should select a GPU even when an NPU is present'
    Assert-True $syclPlan.InstallOneApi 'SYCL-only should retain oneAPI acquisition'
    Assert-True (-not $syclPlan.InstallOpenVino) 'SYCL-only should not acquire OpenVINO'
}
foreach ($nonGpuDevice in @('CPU', 'NPU')) {
    Assert-ThrowsLike {
        Resolve-IntelAiPlan -Architecture X64 -Device $nonGpuDevice -Profile SYCL -IntelGpuPresent $true -IntelNpuPresent $true
    } '*SYCL-only profile supports -Device Auto or GPU*' 'SYCL-only should reject explicit CPU/NPU selections even when hardware is present'
    foreach ($supportedProfile in @('OpenVINO', 'Full')) {
        $plan = Resolve-IntelAiPlan -Architecture X64 -Device $nonGpuDevice -Profile $supportedProfile -IntelGpuPresent $true -IntelNpuPresent $true
        Assert-Equal $plan.Device $nonGpuDevice 'OpenVINO and Full should preserve explicit CPU/NPU selection'
        Assert-True $plan.InstallOpenVino 'OpenVINO and Full should retain OpenVINO acquisition'
        Assert-Equal $plan.InstallOneApi ($supportedProfile -eq 'Full') 'Only Full should also acquire oneAPI for the SYCL GPU kernel'
    }
}
Assert-ThrowsLike {
    Resolve-IntelAiPlan -Architecture Arm64 -Device Auto -Profile OpenVINO -IntelGpuPresent $false
} '*do not publish native Windows ARM64*' 'Intel AI should reject Windows ARM64'
Assert-ThrowsLike {
    Resolve-IntelAiPlan -Architecture X64 -Device GPU -Profile OpenVINO -IntelGpuPresent $false
} '*no Intel display adapter*' 'Explicit Intel GPU should fail without hardware'
Assert-ThrowsLike {
    Resolve-IntelAiPlan -Architecture X64 -Device NPU -Profile OpenVINO -IntelNpuPresent $false
} '*no Intel AI Boost/NPU*' 'Explicit Intel NPU should fail without hardware'

$script = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\Workloads\intel-ai\install.ps1') -Raw
Assert-True ($script -match "ValidateSet\('Auto', 'CPU', 'GPU', 'NPU'\)") 'Intel flow should expose explicit device selection'
Assert-True ($script -match "ValidateSet\('OpenVINO', 'SYCL', 'Full'\)") 'Intel flow should expose runtime/toolkit profiles'
Assert-True ($script -match '\$OpenVinoDeviceId') 'Intel OpenVINO should expose an exact device id for same-vendor adapters'
Assert-True ($script -match '\$SyclDeviceSelector') 'Intel SYCL should expose ONEAPI_DEVICE_SELECTOR for same-vendor adapters'
$probe = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'probe.ps1') -Raw
Assert-True ($probe -match 'OpenVinoDeviceId') 'Intel verification probe should reuse the selected OpenVINO device id'

function Get-CimInstance {
    return @(
        [pscustomobject]@{ Name = 'Intel HD Graphics 4000'; PNPDeviceID = 'PCI\VEN_8086&DEV_0001' },
        [pscustomobject]@{ Name = 'Intel Arc B580 Graphics'; PNPDeviceID = 'PCI\VEN_8086&DEV_0002' }
    )
}
Assert-Equal (Get-IntelGpuName -DeviceIndex 0) 'Intel HD Graphics 4000' 'Intel indexed lookup should preserve exact adapter zero'
Assert-Equal (Get-IntelGpuName -DeviceIndex 1) 'Intel Arc B580 Graphics' 'Intel indexed lookup should preserve exact adapter one'
Assert-True ($script -match '\[switch\]\s*\$PlanOnly') 'Intel flow should support portable plan mode'
Assert-True ($script -notmatch 'apply-configuration') 'Intel flow should use direct acquisition'
Assert-True ($script -match 'Test-PythonDistributionVersions') 'Intel flow should skip package work when exact OpenVINO versions are installed'
$installAst = [Management.Automation.Language.Parser]::ParseInput($script, [ref]$null, [ref]$null)
$runtimeBlock = @($installAst.EndBlock.Statements | Where-Object {
    $_ -is [Management.Automation.Language.IfStatementAst] -and $_.Extent.Text -match '\$vcRedistPackage\b'
})
Assert-Equal $runtimeBlock.Count 1 'Intel OpenVINO should acquire the runtime in one profile-gated block'
Assert-Equal $runtimeBlock[0].Clauses[0].Item1.Extent.Text "`$Profile -in @('OpenVINO', 'Full')" 'SYCL-only should not acquire the OpenVINO runtime prerequisite'
$runtimeStatements = @($runtimeBlock[0].Clauses[0].Item2.Statements | Where-Object { $_.Extent.Text -match '\$vcRedistPackage\b' })
Assert-Equal $runtimeStatements.Count 2 'Intel OpenVINO should acquire and report the runtime'
Assert-True ($runtimeStatements[-1].Extent.EndOffset -lt $runtimeBlock[0].Clauses[0].Item2.Statements[2].Extent.StartOffset) 'Runtime acquisition should precede Python acquisition'
$runtimeCode = [scriptblock]::Create(($runtimeStatements.Extent.Text -join [Environment]::NewLine))
& {
    $architecture = 'X64'
    $failRuntime = $false
    function Ensure-AiWingetPackage {
        param($Id, [switch] $PlanOnly)
        Assert-Equal $Id 'Microsoft.VCRedist.2015+.x64' 'OpenVINO should require the x64 runtime'
        Assert-Equal ([bool]$PlanOnly) $expectedPlanOnly 'Runtime acquisition should preserve plan mode'
        if ($failRuntime) { throw 'Runtime fixture failure' }
        return @{ Id = $Id; Action = $(if ($PlanOnly) { 'planned' } else { 'already-current' }); Evidence = @{ id = $Id } }
    }
    foreach ($PlanOnly in @($true, $false)) {
        $expectedPlanOnly = $PlanOnly
        $report = @{ acquisitions = [Collections.ArrayList]::new() }
        & $runtimeCode
        Assert-Equal $report.acquisitions.Count 1 'Runtime acquisition should append one report entry'
        Assert-Equal $report.acquisitions[0].action $(if ($PlanOnly) { 'planned' } else { 'already-current' }) 'Report should retain the actual runtime action'
        Assert-Equal ($null -eq $report.acquisitions[0].packageEvidence) $PlanOnly 'Planning must not claim installed package evidence'
    }
    $failRuntime = $true
    $report = @{ acquisitions = [Collections.ArrayList]::new() }
    Assert-ThrowsLike { & $runtimeCode } '*Runtime fixture failure*' 'Runtime acquisition errors must propagate'
    Assert-Equal $report.acquisitions.Count 0 'Failed runtime acquisition must not report success'
}

$openvino = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\Workloads\intel-ai\openvino-smoke.py') -Raw
Assert-True ($openvino -match 'compile_model\(model, requested\)') 'OpenVINO acceptance should compile on the requested device'
Assert-True ($openvino -match 'FULL_DEVICE_NAME') 'OpenVINO report should identify the actual device'
$sycl = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\Workloads\intel-ai\sycl-smoke.cpp') -Raw
Assert-True ($sycl -match 'gpu_selector_v') 'SYCL acceptance should require an Intel GPU instead of CPU fallback'
Assert-True ($sycl -match 'parallel_for') 'SYCL acceptance should execute a real kernel'

Write-Host "UNIT_OK: intel-ai ($script:AssertionCount assertions)"
