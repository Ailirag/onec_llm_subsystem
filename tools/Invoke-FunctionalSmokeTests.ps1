[CmdletBinding()]
param(
    [string]$BasePath = (Join-Path $env:LOCALAPPDATA "Ailirag\onec_llm_subsystem\functional-test-base"),
    [int]$TimeoutSeconds = 180
)

$ErrorActionPreference = "Stop"

$repositoryPath = Split-Path $PSScriptRoot -Parent
$buildPath = Join-Path $repositoryPath ".build\functional-tests"
$resultFile = Join-Path $buildPath "smoke-result.txt"
$serverScript = Join-Path $repositoryPath "tests\mock-provider\server.mjs"
$modeRunner = Join-Path $PSScriptRoot "Invoke-1CFunctionalTestMode.ps1"

function Wait-MockProvider {
    param([int]$Seconds)

    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $response = Invoke-RestMethod -Uri "http://127.0.0.1:18081/health" -TimeoutSec 1
            if ($response.status -eq "ok") {
                return
            }
        } catch {
            Start-Sleep -Milliseconds 250
        }
    }
    throw "Mock provider did not become ready on 127.0.0.1:18081."
}

$baseFullPath = [System.IO.Path]::GetFullPath($BasePath)
if (-not (Test-Path -LiteralPath (Join-Path $baseFullPath "1Cv8.1CD"))) {
    throw "Functional test base does not exist. Run tools\Initialize-FunctionalTestEnvironment.ps1 first."
}
New-Item -ItemType Directory -Path $buildPath -Force | Out-Null

$mockProcess = $null
$ownsMockProcess = $false
try {
    try {
        Wait-MockProvider 1
    } catch {
        $node = (Get-Command node -ErrorAction Stop).Source
        $stdout = Join-Path $buildPath "mock-provider.stdout.log"
        $stderr = Join-Path $buildPath "mock-provider.stderr.log"
        $mockProcess = Start-Process -FilePath $node `
            -ArgumentList "`"$serverScript`"" `
            -WorkingDirectory (Split-Path $serverScript -Parent) `
            -WindowStyle Hidden `
            -RedirectStandardOutput $stdout `
            -RedirectStandardError $stderr `
            -PassThru
        $ownsMockProcess = $true
        Wait-MockProvider 10
    }

    Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue
    $testOutput = Join-Path $buildPath "smoke-com.stdout.log"
    $testError = Join-Path $buildPath "smoke-com.stderr.log"
    Remove-Item -LiteralPath $testOutput,$testError -Force -ErrorAction SilentlyContinue
    $testArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$modeRunner`" " +
        "-BasePath `"$baseFullPath`" -Mode smoke -ResultPath `"$resultFile`""
    $testProcess = Start-Process -FilePath "powershell.exe" `
        -ArgumentList $testArguments `
        -WindowStyle Hidden `
        -RedirectStandardOutput $testOutput `
        -RedirectStandardError $testError `
        -PassThru
    if (-not $testProcess.WaitForExit($TimeoutSeconds * 1000)) {
        Stop-Process -Id $testProcess.Id -Force -ErrorAction SilentlyContinue
        throw "Functional smoke tests exceeded timeout of $TimeoutSeconds seconds."
    }
    $testProcess.WaitForExit()
    if (-not (Test-Path -LiteralPath $resultFile)) {
        throw "Test runner did not create result file. See $testError"
    }

    $resultLines = Get-Content -LiteralPath $resultFile -Encoding UTF8
    $resultLines | ForEach-Object { Write-Host $_ }
    if ($resultLines[0] -ne "OK") {
        throw "Functional smoke tests failed. See $resultFile"
    }
} finally {
    if ($ownsMockProcess -and $mockProcess -and -not $mockProcess.HasExited) {
        Stop-Process -Id $mockProcess.Id -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "[OK] Functional smoke tests passed."
