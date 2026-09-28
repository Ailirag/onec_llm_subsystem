[CmdletBinding()]
param(
    [string]$Url = "http://localhost:8081/llm-functional-test",
    [string]$WebTestRunner = ""
)

$ErrorActionPreference = "Stop"

$repositoryPath = Split-Path $PSScriptRoot -Parent
$scenario = Join-Path $repositoryPath "tests\ui\smoke.mjs"

. (Join-Path $PSScriptRoot "WebTestRunner.ps1")
$WebTestRunner = Find-WebTestRunner -Path $WebTestRunner

try {
    $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 10
    if ($response.StatusCode -ne 200) {
        throw "HTTP $($response.StatusCode)"
    }
} catch {
    throw "The 1C web publication is unavailable at $Url. Publish llm-functional-test before running UI smoke tests."
}

Install-WebTestRunnerDependencies -Runner $WebTestRunner

& node $WebTestRunner run $Url $scenario
if ($LASTEXITCODE -ne 0) {
    throw "Functional UI smoke tests failed."
}

Write-Host ""
Write-Host "[OK] Functional UI smoke tests passed."
