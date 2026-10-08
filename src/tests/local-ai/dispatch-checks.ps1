$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\_harness\assertions.ps1')

$bootstrap = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\windows-dev-config\bootstrap.ps1') -Raw
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($bootstrap, [ref]$null, [ref]$parseErrors)
Assert-Equal @($parseErrors).Count 0 'Bootstrap should parse'
$bootstrapFunction = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-CalmOsBootstrap'
}, $true)
. ([scriptblock]::Create($bootstrapFunction.Extent.Text))
Assert-ThrowsLike { Invoke-CalmOsBootstrap -Scenario cuda -AiRuntime Ollama } '*-AiRuntime requires*' 'Standalone installers should reject runtime selection'
Assert-ThrowsLike { Invoke-CalmOsBootstrap -Scenario cuda -AiBackend CPU } '*-AiBackend and -RequireTriton require*' 'Toolkit installers should reject backend selection'
Assert-ThrowsLike { Invoke-CalmOsBootstrap -Scenario ollama -RequireTriton } '*-AiBackend and -RequireTriton require*' 'Runtime installers should reject Triton selection'
Assert-ThrowsLike { Invoke-CalmOsBootstrap -Scenario pytorch -Action Full } '*cannot be combined with -Scenario*' 'AI should not apply workstation actions'
Assert-ThrowsLike { Invoke-CalmOsBootstrap -Scenario foundry -Workload winui } '*cannot be combined with -Scenario*' 'AI should not apply workstation workloads'
Assert-ThrowsLike { Invoke-CalmOsBootstrap -Scenario unknown } '*Cannot validate argument*' 'Unknown installer names should be rejected'

$dispatch = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.IfStatementAst] -and
        $node.Clauses[0].Item1.Extent.Text -eq '$Scenario' -and
        $node.Extent.Text -like '*$scenarioRoot = New-DevConfigProtectedDirectory*'
}, $true)
Assert-True ($null -ne $dispatch) 'Bootstrap should retain protected AI dispatch'
$invokeDispatch = [scriptblock]::Create($dispatch.Extent.Text)
$fixtureRoot = Join-Path $env:TEMP "devconfig-ai-dispatch-$([guid]::NewGuid().ToString('N'))"
$scenarios = @('local-ai', 'pytorch', 'cuda', 'rocm', 'intel-ai', 'llama.cpp', 'ollama', 'foundry')

function New-DevConfigProtectedDirectory {
    param($Path)
    (New-Item -ItemType Directory -Path $Path -Force).FullName
}
function Assert-DevConfigProtectedTree {
    param($Directory)
    $script:protectedChecks += $Directory
}
function Assert-DevConfigMicrosoftSigned {
    param($Directory)
    $script:signatureChecks += $Directory
}
function Unblock-File {
    param([Parameter(ValueFromPipelineByPropertyName)] $FullName)
    process {}
}

try {
    $top = New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'repo') -Force
    $setupDir = (New-Item -ItemType Directory -Path (Join-Path $top.FullName 'windows-dev-config\steps') -Force).Parent.FullName
    Set-Content -LiteralPath (Join-Path $setupDir 'steps\fixture.ps1') -Value ''
    foreach ($tree in @('Workloads', 'src\Workloads')) {
        foreach ($name in $scenarios) {
            $directory = New-Item -ItemType Directory -Path (Join-Path $top.FullName "$tree\$name") -Force
            Set-Content -LiteralPath (Join-Path $directory.FullName 'install.ps1') -Value ''
        }
        $common = New-Item -ItemType Directory -Path (Join-Path $top.FullName "$tree\_common") -Force
        @'
function Assert-DevConfigWorkloadContent {
    param($WorkloadsRoot)
    $script:contentChecks += $WorkloadsRoot
}
'@ | Set-Content -LiteralPath (Join-Path $common.FullName 'content-hashes.ps1')
    }
    $Ref = 'a' * 40
    $InstallRoot = Join-Path $fixtureRoot 'installed'
    $ReportRoot = Join-Path $fixtureRoot "reports\O'Brien"
    $escapedShell = 'fixture-shell'
    $shell = {
        $script:childArguments = @($args)
        $global:LASTEXITCODE = $childExitCode
    }
    foreach ($Scenario in $scenarios) {
        $AiBackend = if ($Scenario -in @('local-ai', 'pytorch')) { 'CPU' } else { 'Auto' }
        $AiRuntime = if ($Scenario -eq 'local-ai') { 'Ollama' } else { 'None' }
        $RequireTriton = $Scenario -in @('local-ai', 'pytorch')
        $PlanOnly = $true
        foreach ($AllowUnsigned in @($false, $true)) {
            foreach ($NoLaunch in @($false, $true)) {
                $work = New-DevConfigProtectedDirectory -Path (Join-Path $fixtureRoot 'download')
                $script:protectedChecks = @()
                $script:signatureChecks = @()
                $script:contentChecks = @()
                $script:childArguments = @()
                $childExitCode = 0
                . $invokeDispatch 6>$null
                $expectedTarget = Join-Path $InstallRoot "Scenarios\$Scenario\Workloads\$Scenario\install.ps1"
                Assert-True (Test-Path -LiteralPath $expectedTarget) 'Selected installer should be copied to its isolated scenario directory'
                Assert-True (Test-Path -LiteralPath (Join-Path $InstallRoot "Scenarios\$Scenario\windows-dev-config\steps\fixture.ps1")) 'AI should retain shared helper files'
                Assert-Equal $script:protectedChecks.Count 2 'AI should protect downloaded and installed trees'
                Assert-Equal $script:signatureChecks.Count $(if ($AllowUnsigned) { 0 } else { 2 }) 'Signed AI should verify both trees'
                Assert-Equal $script:contentChecks.Count 2 'AI should check content hashes before and after copy'
                Assert-Equal $script:childArguments.Count $(if ($NoLaunch) { 0 } else { $scenarioArguments.Count }) 'NoLaunch should not execute the installer'
                Assert-Equal $scenarioArguments[$scenarioArguments.IndexOf('-File') + 1] $expectedTarget 'Dispatch should select only the requested installer'
                Assert-Equal ($scenarioArguments -contains '-ExecutionPolicy') (-not $AllowUnsigned) 'Signed dispatch should retain RemoteSigned'
                Assert-Equal ($scenarioArguments -contains '-Backend') ($Scenario -in @('local-ai', 'pytorch')) 'Only PyTorch and local AI should receive backend selection'
                Assert-Equal ($scenarioArguments -contains '-Runtime') ($Scenario -eq 'local-ai') 'Only local AI should receive runtime selection'
                Assert-Equal ($scenarioArguments -contains '-RequireTriton') $RequireTriton 'Dispatch should preserve Triton selection'
                Assert-True ($scenarioArguments -contains '-PlanOnly') 'Dispatch should preserve planning mode'
                $reportParameter = if ($Scenario -eq 'local-ai') { '-ReportRoot' } else { '-ReportPath' }
                $expectedReport = if ($Scenario -eq 'local-ai') { $ReportRoot } else { Join-Path $ReportRoot "$Scenario.json" }
                Assert-Equal $scenarioArguments[$scenarioArguments.IndexOf($reportParameter) + 1] $expectedReport 'Dispatch should map report paths to installer parameters'
            }
        }
        $NoLaunch = $false
        $childExitCode = 7
        $work = New-DevConfigProtectedDirectory -Path (Join-Path $fixtureRoot 'download')
        Assert-ThrowsLike { & $invokeDispatch 6>$null } '*scenario finished with exit code 7*' 'Installer failures should propagate'
    }
} finally {
    if (Test-Path -LiteralPath $fixtureRoot) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
    }
}

Write-Host "UNIT_OK: AI dispatch ($script:AssertionCount assertions)"
