[CmdletBinding()]
param(
    [string]$Url = "http://localhost:8081/llm-functional-test",
    [string]$WebTestRunner = ""
)

$ErrorActionPreference = "Stop"

$repositoryPath = Split-Path $PSScriptRoot -Parent
$scenario = Join-Path $repositoryPath "tests\ui\smoke.mjs"

if (-not $WebTestRunner) {
    $skillsRoot = Join-Path $env:USERPROFILE ".codex\plugins\cache\cc-1c-skills\1c-skills"
    $WebTestRunner = Get-ChildItem -LiteralPath $skillsRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        ForEach-Object {
            Join-Path $_.FullName ".codex\skills\web-test\scripts\run.mjs"
        } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Select-Object -First 1
}
if (-not $WebTestRunner -or -not (Test-Path -LiteralPath $WebTestRunner -PathType Leaf)) {
    throw "The cc-1c-skills web-test runner was not found. Install the cc-1c-skills plugin or pass -WebTestRunner."
}

try {
    $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 10
    if ($response.StatusCode -ne 200) {
        throw "HTTP $($response.StatusCode)"
    }
} catch {
    throw "The 1C web publication is unavailable at $Url. Publish llm-functional-test before running UI smoke tests."
}

$runnerDirectory = Split-Path $WebTestRunner -Parent
if (-not (Test-Path -LiteralPath (Join-Path $runnerDirectory "node_modules"))) {
    & npm.cmd ci --prefix $runnerDirectory
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to install web-test runner dependencies."
    }
}

& node $WebTestRunner run $Url $scenario
if ($LASTEXITCODE -ne 0) {
    throw "Functional UI smoke tests failed."
}

Write-Host ""
Write-Host "[OK] Functional UI smoke tests passed."
