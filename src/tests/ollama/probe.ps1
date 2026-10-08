$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\..\Workloads\_common\ai-support.ps1')

$apiBase = Get-OllamaLocalEndpoint
$oldHost = $env:OLLAMA_HOST
try {
    $env:OLLAMA_HOST = $apiBase
    if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
        throw 'ollama was not found on PATH.'
    }
    & ollama --version *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "ollama --version failed with exit code $LASTEXITCODE."
    }
    $plan = Get-OllamaModelSmokePlan
    $request = New-OllamaGenerateRequest -Model $plan.Model -Marker $plan.Marker
    $response = Invoke-RestMethod `
        -Method Post `
        -Uri "$apiBase/api/generate" `
        -ContentType 'application/json' `
        -Body ($request | ConvertTo-Json -Depth 8) `
        -TimeoutSec 300
    $result = $response.response | ConvertFrom-Json
    if ($result.marker -ne $plan.Marker) {
        throw 'Ollama cached-model inference did not return the expected marker.'
    }
} finally {
    $env:OLLAMA_HOST = $oldHost
}

Write-Output 'Ollama ready'
