[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$null = Get-Command dotnet -ErrorAction Stop
$null = Get-Command winapp -ErrorAction Stop

$null = & dotnet --version
if ($LASTEXITCODE -ne 0) {
    throw "dotnet --version exited with code $LASTEXITCODE"
}

$null = & winapp --version
if ($LASTEXITCODE -ne 0) {
    throw "winapp --version exited with code $LASTEXITCODE"
}

Write-Output 'OK'
