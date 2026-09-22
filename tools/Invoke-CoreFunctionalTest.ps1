[CmdletBinding()]
param(
    [string]$BasePath = (Join-Path $env:LOCALAPPDATA "Ailirag\onec_llm_subsystem\functional-test-base"),
    [int]$TimeoutSeconds = 90,
    [switch]$Background,
    [string]$V8Path = 'C:\Program Files\1cv8\8.3.27.2130\bin\1cv8.exe'
)

$ErrorActionPreference = "Stop"

$repositoryPath = Split-Path $PSScriptRoot -Parent
$buildPath = Join-Path $repositoryPath ".build\functional-tests"
$serverScript = Join-Path $repositoryPath "tests\mock-provider\server.mjs"

function Wait-MockProvider {
    param([int]$Seconds)

    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $response = Invoke-RestMethod -Uri "http://127.0.0.1:18081/health" -TimeoutSec 1
            if ($response.status -eq "ok") {
                return
            }
        }
        catch {
            Start-Sleep -Milliseconds 250
        }
    }
    throw "Mock provider did not become ready on 127.0.0.1:18081."
}

$baseFullPath = [System.IO.Path]::GetFullPath($BasePath)
if (-not (Test-Path -LiteralPath (Join-Path $baseFullPath "1Cv8.1CD"))) {
    throw "Functional test base does not exist."
}
New-Item -ItemType Directory -Path $buildPath -Force | Out-Null

$mockProcess = $null
$ownsMockProcess = $false
$connection = $null
$clientProcess = $null
try {
    try {
        Wait-MockProvider 1
    }
    catch {
        $node = (Get-Command node -ErrorAction Stop).Source
        $stdout = Join-Path $buildPath "core-mock-provider.stdout.log"
        $stderr = Join-Path $buildPath "core-mock-provider.stderr.log"
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

    if ($Background) {
        $key = 'background-' + [Guid]::NewGuid().ToString('N')
        $resultFile = Join-Path $buildPath "$key.txt"
        $logFile = Join-Path $buildPath "$key.log"
        $clientProcess = Start-Process -FilePath $V8Path -WindowStyle Hidden -PassThru `
            -ArgumentList @('ENTERPRISE', "/F`"$baseFullPath`"", '/DisableStartupDialogs',
                '/DisableStartupMessages',
                "/C`"LLMCORE|$resultFile|$key`"", "/Out`"$logFile`"")
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        while ([DateTime]::UtcNow -lt $deadline -and -not (Test-Path -LiteralPath $resultFile)) {
            if ($clientProcess.HasExited) { throw "Background test client exited without a result. See $logFile" }
            Start-Sleep -Milliseconds 500
        }
        if (-not (Test-Path -LiteralPath $resultFile)) { throw "Background test timed out. See $logFile" }
        $backgroundResult = Get-Content -LiteralPath $resultFile -Raw -Encoding UTF8
        Write-Host $backgroundResult
        if (-not $backgroundResult.StartsWith('OK|')) { throw $backgroundResult }
        Write-Host '[OK] Enterprise client background execution and model response passed.'
        exit 0
    }

    $connector = New-Object -ComObject "V83.COMConnector"
    $connectionString = "File=`"$baseFullPath`";"
    $connection = $connector.Connect($connectionString)
    $idempotencyKey = "core-" + [Guid]::NewGuid().ToString("N")
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)

    while ([DateTime]::UtcNow -lt $deadline) {
        $result = [string]$connection.RunCore($idempotencyKey, (-not $Background))
        $parts = $result -split '\|', 3
        if ($parts[0] -eq "OK") {
            Write-Host $result
            $executionMode = if ($Background) { 'background worker' } else { 'direct worker' }
            Write-Host "[OK] Public core API, idempotency, $executionMode execution and model response passed."
            $queueResult = [string]$connection.RunQueue()
            Write-Host $queueResult
            if (-not $queueResult.StartsWith('OK|')) { throw $queueResult }
            $contractResult = [string]$connection.RunContracts()
            Write-Host $contractResult
            if (-not $contractResult.StartsWith('OK|')) { throw $contractResult }
            $migrationResult = [string]$connection.RunMigration()
            Write-Host $migrationResult
            if (-not $migrationResult.StartsWith('OK|')) { throw $migrationResult }
            exit 0
        }
        if ($parts[0] -eq "ERROR") {
            throw $result
        }
        if ($parts[0] -ne "WAIT") {
            throw "Unexpected core test response: $result"
        }
        Start-Sleep -Milliseconds 300
    }

    throw "Core functional test exceeded timeout of $TimeoutSeconds seconds."
}
finally {
    if ($null -ne $connection) {
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($connection)
    }
    if ($ownsMockProcess -and $mockProcess -and -not $mockProcess.HasExited) {
        Stop-Process -Id $mockProcess.Id -Force -ErrorAction SilentlyContinue
    }
    if ($clientProcess -and -not $clientProcess.HasExited) {
        Stop-Process -Id $clientProcess.Id -ErrorAction SilentlyContinue
    }
}
