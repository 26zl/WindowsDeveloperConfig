$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\_harness\assertions.ps1')

$bootstrapFixture = @'
param([string] $Ref, [string] $Scenario, [string] $AiRuntime = 'None')
[pscustomobject]@{ Ref = $Ref; Scenario = $Scenario; AiRuntime = $AiRuntime }
'@
$microsoftSubject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
$originalModulePath = $env:PSModulePath
$originalProtocol = [Net.ServicePointManager]::SecurityProtocol

function Invoke-RestMethod {
    param($Uri, [switch] $UseBasicParsing, $TimeoutSec)
    Assert-Equal $Uri "https://raw.githubusercontent.com/microsoft/WindowsDeveloperConfig/$payloadRef/windows-dev-config/bootstrap.ps1" 'Launcher should download bootstrap from its payload ref'
    Assert-True $UseBasicParsing.IsPresent 'Launcher should support Windows PowerShell'
    Assert-Equal $TimeoutSec 60 'Launcher should bound its download wait'
    return ([char]0xFEFF + $bootstrapFixture)
}

function Get-AuthenticodeSignature {
    param([byte[]] $Content, [string] $SourcePathOrExtension)
    Assert-Equal ([Text.Encoding]::Unicode.GetString($Content)) $bootstrapFixture 'Launcher should verify BOM-stripped UTF-16LE bootstrap content'
    Assert-Equal $SourcePathOrExtension '.ps1' 'Launcher should verify a PowerShell signature'
    return $signatureFixture
}

try {
    foreach ($case in @(
        @{ File = 'local-ai\setup.ps1'; Scenario = 'local-ai'; Runtime = 'None' }
        @{ File = 'local-ai\llama.cpp\setup.ps1'; Scenario = 'local-ai'; Runtime = 'LlamaCpp' }
        @{ File = 'local-ai\ollama\setup.ps1'; Scenario = 'local-ai'; Runtime = 'Ollama' }
        @{ File = 'local-ai\foundry\setup.ps1'; Scenario = 'local-ai'; Runtime = 'Foundry' }
        @{ File = 'pytorch\setup.ps1'; Scenario = 'pytorch'; Runtime = 'None' }
        @{ File = 'cuda\setup.ps1'; Scenario = 'cuda'; Runtime = 'None' }
        @{ File = 'rocm\setup.ps1'; Scenario = 'rocm'; Runtime = 'None' }
        @{ File = 'intel-ai\setup.ps1'; Scenario = 'intel-ai'; Runtime = 'None' }
        @{ File = 'llama.cpp\setup.ps1'; Scenario = 'llama.cpp'; Runtime = 'None' }
        @{ File = 'ollama\setup.ps1'; Scenario = 'ollama'; Runtime = 'None' }
        @{ File = 'foundry\setup.ps1'; Scenario = 'foundry'; Runtime = 'None' }
    )) {
        $launcher = Join-Path $PSScriptRoot "..\..\Workloads\$($case.File)"
        $launch = [scriptblock]::Create((Get-Content -LiteralPath $launcher -Raw))
        $signatureFixture = [pscustomobject]@{
            Status = 'Valid'
            SignerCertificate = [pscustomobject]@{ Subject = $microsoftSubject }
        }
        $result = Get-Content -LiteralPath $launcher -Raw | Invoke-Expression
        Assert-True ($result.Ref -match '^(main|[a-f0-9]{40})$') 'Launcher should forward main or a full payload commit SHA'
        Assert-Equal $result.Scenario $case.Scenario 'Launcher should select its fixed AI scenario'
        Assert-Equal $result.AiRuntime $case.Runtime 'Launcher should select its fixed runtime'
        foreach ($invalidSignature in @(
            [pscustomobject]@{ Status = 'NotSigned'; SignerCertificate = $null }
            [pscustomobject]@{ Status = 'HashMismatch'; SignerCertificate = [pscustomobject]@{ Subject = $microsoftSubject } }
            [pscustomobject]@{ Status = 'Valid'; SignerCertificate = $null }
            [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Other' } }
        )) {
            $signatureFixture = $invalidSignature
            Assert-ThrowsLike { & $launch } '*failed Microsoft signature verification*' 'Launcher should reject untrusted bootstrap content'
        }
    }
} finally {
    $env:PSModulePath = $originalModulePath
    [Net.ServicePointManager]::SecurityProtocol = $originalProtocol
}

Write-Host "UNIT_OK: local-ai launchers ($script:AssertionCount assertions)"
