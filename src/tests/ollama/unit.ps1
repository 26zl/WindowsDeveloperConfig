$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\_harness\assertions.ps1')
. (Join-Path $PSScriptRoot '..\..\Workloads\_common\ai-support.ps1')

foreach ($architecture in @('X64', 'Arm64')) {
    $plan = Resolve-OllamaInstallPlan -Architecture $architecture
    Assert-Equal $plan.Method 'WinGet' "Ollama $architecture should use WinGet"
    Assert-Equal $plan.PackageId 'Ollama.Ollama' "Ollama $architecture should use the installed application package"
    Assert-Equal $plan.LaunchMode 'InstalledApplication' "Ollama $architecture should use normal application semantics"
}

$catalog = (Get-AiCatalogData).Components
foreach ($entry in @($catalog.OllamaX64, $catalog.OllamaArm64)) {
    Assert-Equal $entry.SourceType 'winget' 'Every Ollama architecture should select WinGet'
    Assert-Equal $entry.PackageId 'Ollama.Ollama' 'Every Ollama architecture should select the exact package ID'
    Assert-Equal $entry.Maturity 'stable' 'Every selected Ollama package should be stable'
}
Assert-True ($catalog.OllamaArm64.MigrationTrigger -match 'Achieved') 'ARM64 stable-channel tracker should record the achieved promotion'
Assert-True ($catalog.OllamaArm64.NormalChannelLimitation -match '0\.40\.0') 'ARM64 metadata should identify the first qualified shared installer'
$catalogText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\Workloads\_common\ai-catalog.psd1') -Raw
Assert-True ($catalogText -notmatch 'Ollama\.Ollama\.Portable') 'Ollama should never select the portable package'
Assert-True ($catalogText -notmatch 'ollama-windows-arm64\.zip') 'ARM64 archive acquisition should be retired'

$script:manifestExitCode = 0
$script:manifestOutput = @'
Found Ollama [Ollama.Ollama]
Version: 0.40.0
Installer:
  Installer Type: inno
  Installer Url: https://github.com/ollama/ollama/releases/download/v0.40.0/OllamaSetup.exe
  Installer SHA256: 135bf4d927b1de03e884cd2fe66729bdf4d6a2983c5a453b99eb403489e460e1
'@
function Invoke-DevConfigNativeCommand {
    param($FilePath, $Arguments)
    Assert-Equal $FilePath 'winget.exe' 'Manifest evidence should use winget.exe'
    Assert-True ('--architecture' -in $Arguments) 'Manifest evidence should request an architecture'
    [pscustomobject]@{ ExitCode = $script:manifestExitCode; Output = $script:manifestOutput }
}
foreach ($architecture in @('X64', 'Arm64')) {
    $evidence = Get-OllamaWingetManifestEvidence -Architecture $architecture
    Assert-True $evidence.Applicable "WinGet should report an applicable $architecture installer"
    Assert-Equal $evidence.Version '0.40.0' 'Installer version should come from the official release URL'
    Assert-Equal $evidence.InstallerUrl 'https://github.com/ollama/ollama/releases/download/v0.40.0/OllamaSetup.exe' 'Selected installer should be the official setup EXE'
    Assert-Equal $evidence.InstallerSha256 '135bf4d927b1de03e884cd2fe66729bdf4d6a2983c5a453b99eb403489e460e1' 'Selected installer digest should match the WinGet manifest'
}
$script:manifestExitCode = 1
Assert-ThrowsLike {
    Get-OllamaWingetManifestEvidence -Architecture Arm64
} '*no applicable Arm64 WinGet installer*' 'Missing architecture applicability should fail before mutation'
$script:manifestExitCode = 0

$uninstallCommand = ConvertFrom-OllamaUninstallString `
    -UninstallString '"C:\TestData\Programs\Ollama\unins000.exe" /CURRENTUSER'
Assert-Equal $uninstallCommand.FilePath 'C:\TestData\Programs\Ollama\unins000.exe' 'Registered uninstaller should preserve the quoted executable path'
Assert-Equal $uninstallCommand.Arguments '/CURRENTUSER' 'Registered uninstaller should preserve existing arguments'

foreach ($endpoint in @(
    @{ HostValue = $null; Expected = 'http://127.0.0.1:11434' }
    @{ HostValue = 'localhost:12345'; Expected = 'http://localhost:12345' }
    @{ HostValue = '[::1]:12345'; Expected = 'http://[::1]:12345' }
)) {
    Assert-Equal ([uri](Get-OllamaLocalEndpoint -HostValue $endpoint.HostValue)) ([uri]$endpoint.Expected) 'Ollama endpoint should remain loopback-only'
}
Assert-ThrowsLike {
    Get-OllamaLocalEndpoint -HostValue 'remote.example.invalid:11434'
} '*loopback address*' 'Remote endpoints should remain unsupported'

$pathsRoot = Join-Path $env:TEMP "devconfig-ollama-migration-$([guid]::NewGuid().ToString('N'))"
$paths = [pscustomobject]@{
    InstallRoot = Join-Path $pathsRoot 'Programs\Ollama'
    InstallManifest = Join-Path $pathsRoot 'Programs\Ollama\.devconfig-install.json'
    VersionMarker = '.devconfig-version'
    LegacyRoot = Join-Path $pathsRoot 'legacy'
    CacheDirectory = Join-Path $pathsRoot 'cache'
    StartupRegistryPath = "HKCU:\Software\WindowsDeveloperConfigTests\$([guid]::NewGuid())"
    StartupValueName = 'WindowsDeveloperConfig.Ollama'
}
$models = Join-Path $pathsRoot 'models'
try {
    $notRequired = Remove-OllamaLegacyManagedInstallation -Paths $paths
    Assert-True (-not $notRequired.Migrated) 'Migration cleanup should not touch a normal WinGet installation'

    New-Item -ItemType Directory -Path $paths.InstallRoot, $paths.LegacyRoot, $paths.CacheDirectory, $models -Force | Out-Null
    Set-Content -LiteralPath $paths.InstallManifest -Value '{}'
    Set-Content -LiteralPath (Join-Path $paths.InstallRoot 'ollama.exe') -Value 'legacy'
    Set-Content -LiteralPath (Join-Path $models 'model') -Value 'preserve'
    New-Item -Path $paths.StartupRegistryPath -Force | Out-Null
    Set-ItemProperty -LiteralPath $paths.StartupRegistryPath -Name $paths.StartupValueName -Value 'legacy startup'
    $migrated = Remove-OllamaLegacyManagedInstallation -Paths $paths
    Assert-True $migrated.Migrated 'Legacy managed archive should be migrated'
    Assert-True $migrated.RuntimeRemoved 'Legacy runtime should be removed before WinGet installation'
    Assert-True $migrated.ModelsPreserved 'Migration should preserve model data'
    Assert-True (Test-Path -LiteralPath $models) 'Migration should leave models on disk'
    Assert-True (-not (Get-ItemProperty -LiteralPath $paths.StartupRegistryPath -Name $paths.StartupValueName -ErrorAction SilentlyContinue)) 'Migration should remove the Dev Config startup value'
} finally {
    Remove-Item -LiteralPath $paths.StartupRegistryPath -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $pathsRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$model = Get-OllamaModelSmokePlan
Assert-Equal $model.Model 'qwen3:0.6b' 'Ollama should retain the quick validation model'
Assert-Equal $model.ModelBlobSha256 '7f4030143c1c477224c5434f8272c662a8b042079a0a584f0a27a1684fe2e1fa' 'Quick model blob should remain pinned'

$installScript = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\Workloads\ollama\install.ps1') -Raw
Assert-True ($installScript -match 'Get-OllamaWingetManifestEvidence') 'Ollama should verify package applicability before mutation'
Assert-True ($installScript -match 'Ensure-AiWingetPackage -Id \$plan\.PackageId') 'Both architectures should acquire the exact WinGet package'
Assert-True ($installScript -match 'Remove-OllamaLegacyManagedInstallation') 'ARM64 should migrate the prior Dev Config archive'
Assert-True ($installScript -match 'Get-AiPeArchitecture') 'Installed executable architecture should be verified'
Assert-True ($installScript -match 'selectedInstaller') 'Reports should include the selected installer URL and digest'
Assert-True ($installScript -match 'Invoke-DevConfigCleanupCommand') 'Uninstall should be idempotent through WinGet'
Assert-True ($installScript -match 'winget-registered-uninstaller') 'Elevated user-scope uninstall should use the WinGet-registered uninstaller fallback'
Assert-True ($installScript -match 'retained-user-scope-not-selected') 'A pre-existing user-scope portable package should be reported without blocking the official application'
Assert-True ($installScript -notmatch 'Install-VerifiedGitHubLatestAsset') 'Ollama should no longer acquire the ARM64 archive'
Assert-True ($installScript -notmatch 'Set-OllamaStartupRegistration') 'Ollama should no longer create a Dev Config startup registration'
Assert-True ($installScript -notmatch 'native-arm64-managed-archive') 'User-facing reports should use normal installed application semantics'

$tokens = $null
$parseErrors = $null
$installAst = [Management.Automation.Language.Parser]::ParseInput($installScript, [ref]$tokens, [ref]$parseErrors)
Assert-Equal $parseErrors.Count 0 'Ollama installer should parse'
$statements = @($installAst.EndBlock.Statements)
$lookup = @($statements | Where-Object { $_.Extent.Text -like '$manifestEvidence = Get-OllamaWingetManifestEvidence*' })
$uninstallBranch = @($statements | Where-Object {
    $_ -is [Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -eq '$Uninstall'
})
$reportInitialization = @($statements | Where-Object { $_.Extent.Text -like '$report = New-AiWorkloadReport*' })
Assert-Equal $lookup.Count 1 'Manifest lookup should occur once at script scope'
Assert-Equal $uninstallBranch.Count 1 'Installer should have one uninstall branch'
Assert-True ($lookup[0].Extent.StartOffset -gt $uninstallBranch[0].Extent.EndOffset) 'Uninstall should finish before manifest lookup'
Assert-True ($lookup[0].Extent.StartOffset -gt $reportInitialization[0].Extent.EndOffset) 'Report should exist before manifest lookup'
Assert-Equal $uninstallBranch[0].Clauses[0].Item2.Statements[-1].GetType().Name 'ReturnStatementAst' 'Uninstall should return before manifest lookup'

& {
    . (Join-Path $PSScriptRoot '..\..\Workloads\_common\ai-report.ps1')
    $helper = $statements | Where-Object {
        $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq 'Add-OllamaAcquisition'
    }
    . ([scriptblock]::Create($helper.Extent.Text))
    $component = $catalog.OllamaX64
    $architecture = 'X64'
    $report = @{ acquisitions = [Collections.ArrayList]::new() }
    $Uninstall = $true
    Add-OllamaAcquisition -Action 'uninstalled' -PackageEvidence $null -MigrationEvidence $null
    Assert-True (-not $report.acquisitions[0].Contains('selectedInstaller')) 'Uninstall reporting should not require manifest evidence'

    $Uninstall = $false
    $manifestEvidence = [pscustomobject]@{
        Applicable = $true; Architecture = 'X64'; Version = '0.40.0'
        InstallerUrl = 'https://example.invalid/OllamaSetup.exe'; InstallerSha256 = 'test-digest'
    }
    Add-OllamaAcquisition -Action 'installed' -PackageEvidence $null -MigrationEvidence $null
    Assert-Equal $report.acquisitions[1].selectedInstaller.version '0.40.0' 'Install reporting should retain manifest evidence'

    function Write-DevConfigTextFile {
        param($Path, $Content)
        Assert-Equal $Path 'mock-report.json' 'Manifest failures should use the requested report path'
        $script:ollamaFailureReport = $Content | ConvertFrom-Json
    }
    $report = @{ completedAtUtc = $null; result = @{ ready = $true; blockers = [Collections.ArrayList]::new() } }
    $ReportPath = 'mock-report.json'
    function Get-OllamaWingetManifestEvidence { param($Architecture) throw 'mock manifest failure' }
    $failureCode = ($installAst.EndBlock.Traps.Extent.Text -join [Environment]::NewLine) + [Environment]::NewLine + $lookup[0].Extent.Text
    Assert-ThrowsLike { & ([scriptblock]::Create($failureCode)) } '*mock manifest failure*' 'Manifest lookup failures should preserve the original error'
    Assert-True (-not $script:ollamaFailureReport.result.ready) 'Manifest lookup failures should produce a failed report'
    Assert-Equal $script:ollamaFailureReport.result.blockers[0] 'mock manifest failure' 'Failure report should record the manifest error'
    Remove-Variable -Name ollamaFailureReport -Scope Script
}

function Get-CimInstance {
    @(
        [pscustomobject]@{
            ProcessId = 101
            ExecutablePath = 'C:\TestData\Programs\Ollama\ollama.exe'
        }
        [pscustomobject]@{
            ProcessId = 202
            ExecutablePath = 'C:\Program Files\Other\ollama.exe'
        }
    )
}
$scoped = @(Get-OllamaManagedProcesses -InstallRoot 'C:\TestData\Programs\Ollama')
Assert-Equal $scoped.Count 1 'Process cleanup should remain scoped to the selected application directory'
Assert-Equal $scoped[0].ProcessId 101 'Process cleanup should not target unrelated Ollama installations'

Write-Host "UNIT_OK: ollama ($script:AssertionCount assertions)"
