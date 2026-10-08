$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\..\Workloads\_common\ai-support.ps1')
. (Join-Path $PSScriptRoot '..\..\Workloads\_common\ai-report.ps1')
. (Join-Path $PSScriptRoot '..\..\windows-dev-config\steps\_environment.ps1')

$architecture = Get-DevConfigArchitecture
$plan = Resolve-CudaInstallPlan -Architecture $architecture -WindowsBuild (Get-WindowsBuildNumber)
$reportPath = Get-AiDefaultReportPath -Id 'cuda'
$deviceIndex = 0
if (Test-Path -LiteralPath $reportPath) {
    $request = (Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json).request
    if ($request.PSObject.Properties['DeviceIndex']) { $deviceIndex = [int]$request.DeviceIndex }
}
$driver = Get-NvidiaDriverInfo -DeviceIndex $deviceIndex
if (-not $driver) {
    throw "CUDA probe could not qualify NVIDIA device index $deviceIndex. Ensure nvidia-smi is available and reports a usable driver."
}
$nvcc = Get-CudaNvccPath -ToolkitVersion $plan.ToolkitVersion
$vsDevCmd = Get-VsDevCmdPath -Architecture $architecture
$temporary = Join-Path ([System.IO.Path]::GetTempPath()) "devconfig-cuda-probe-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $temporary -Force | Out-Null
try {
    $executable = Join-Path $temporary 'cuda-smoke.exe'
    $compile = Get-CudaKernelCompileCommand `
        -Architecture $architecture `
        -VsDevCmd $vsDevCmd `
        -Nvcc $nvcc `
        -Source (Join-Path $PSScriptRoot '..\..\Workloads\cuda\smoke.cu') `
        -Output $executable
    & $env:ComSpec /d /s /c $compile *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "CUDA probe compilation failed with exit code $LASTEXITCODE."
    }
    $result = (& $executable $deviceIndex 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "CUDA probe kernel failed with exit code $LASTEXITCODE and output '$result'."
    }
    $null = Get-CudaKernelDeviceEvidence -Output $result -ExpectedDeviceName $driver.Name -DeviceIndex $deviceIndex
} finally {
    Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'CUDA ready'
