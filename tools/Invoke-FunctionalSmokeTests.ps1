[CmdletBinding()]
param(
    [string]$BasePath = (Join-Path $env:LOCALAPPDATA "Ailirag\onec_llm_subsystem\functional-test-base"),
    [int]$TimeoutSeconds = 180,
    # HTTP-публикация стенда этому набору не нужна: обращения к провайдеру идут
    # из 1С к локальному mock-сервису. Ключ принимается по контракту workflow.
    [switch]$SkipHttp
)

$ErrorActionPreference = "Stop"

$repositoryPath = Split-Path $PSScriptRoot -Parent
$buildPath = Join-Path $repositoryPath ".build\functional-tests"
$resultFile = Join-Path $buildPath "smoke-result.txt"
$serverScript = Join-Path $repositoryPath "tests\mock-provider\server.mjs"
$modeRunner = Join-Path $PSScriptRoot "Invoke-1CFunctionalTestMode.ps1"

function Assert-KnowledgeBundleHelpRegistration {
    $catalogRoot = Join-Path $repositoryPath "cfe llm\Catalogs"
    $ownerPath = Join-Path $catalogRoot "AI_НаборыЗнаний.xml"
    $helpRoot = Join-Path $catalogRoot "AI_НаборыЗнаний\Ext"
    $descriptorPath = Join-Path $helpRoot "Help.xml"
    $pagePath = Join-Path $helpRoot "Help\ru.html"

    foreach ($path in @($ownerPath, $descriptorPath, $pagePath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Knowledge bundles F1 help file is missing: $path"
        }
    }

    [xml]$owner = Get-Content -Raw -LiteralPath $ownerPath -Encoding UTF8
    $include = $owner.SelectSingleNode(
        "/*[local-name()='MetaDataObject']/*[1]/*[local-name()='Properties']/*[local-name()='IncludeHelpInContents']")
    if ($null -eq $include -or ([string]$include.InnerText).Trim().ToLowerInvariant() -ne "true") {
        throw "Knowledge bundles F1 help is not enabled on the catalog owner."
    }

    [xml]$descriptor = Get-Content -Raw -LiteralPath $descriptorPath -Encoding UTF8
    $ruPage = @($descriptor.SelectNodes("/*[local-name()='Help']/*[local-name()='Page']")) |
        Where-Object { ([string]$_.InnerText).Trim() -eq "ru" }
    if (@($ruPage).Count -ne 1) {
        throw "Knowledge bundles F1 help descriptor does not declare the ru page exactly once."
    }

    $plainText = ((Get-Content -Raw -LiteralPath $pagePath -Encoding UTF8) -replace "<[^>]+>", "").Trim()
    if ($plainText.Length -le 40) {
        throw "Knowledge bundles F1 help page is empty."
    }
}

function Assert-McpSecretAccessContract {
    $restrictedRoles = @("AI_ПользовательLLM", "AI_АнализДанныхАгентом")
    foreach ($role in $restrictedRoles) {
        $rightsPath = Join-Path $repositoryPath "cfe llm\Roles\$role\Ext\Rights.xml"
        [xml]$rights = Get-Content -Raw -LiteralPath $rightsPath -Encoding UTF8
        $secretRight = $rights.SelectSingleNode(
            "//*[local-name()='object'][*[local-name()='name']='InformationRegister.AI_СекретыMCP']")
        if ($null -ne $secretRight) {
            throw "Role $role must not read the MCP secret register: $rightsPath"
        }
    }

    $administratorRightsPath = Join-Path $repositoryPath `
        "cfe llm\Roles\AI_АдминистраторMCP\Ext\Rights.xml"
    [xml]$administratorRights = Get-Content -Raw -LiteralPath $administratorRightsPath -Encoding UTF8
    $administratorSecretRight = $administratorRights.SelectSingleNode(
        "//*[local-name()='object'][*[local-name()='name']='InformationRegister.AI_СекретыMCP']")
    if ($null -eq $administratorSecretRight) {
        throw "MCP administrator has no access to the MCP secret register."
    }

    $modulePath = Join-Path $repositoryPath "cfe llm\CommonModules\AI_MCPСекреты.xml"
    [xml]$module = Get-Content -Raw -LiteralPath $modulePath -Encoding UTF8
    $properties = $module.SelectSingleNode(
        "//*[local-name()='CommonModule']/*[local-name()='Properties']")
    $server = $properties.SelectSingleNode("*[local-name()='Server']").InnerText.Trim().ToLowerInvariant()
    $serverCall = $properties.SelectSingleNode("*[local-name()='ServerCall']").InnerText.Trim().ToLowerInvariant()
    $privileged = $properties.SelectSingleNode("*[local-name()='Privileged']").InnerText.Trim().ToLowerInvariant()
    if ($server -ne "true" -or $serverCall -ne "false" -or $privileged -ne "false") {
        throw "AI_MCPСекреты must be server-only, unavailable for client server calls, and not metadata-privileged."
    }

    $moduleSourcePath = Join-Path $repositoryPath `
        "cfe llm\CommonModules\AI_MCPСекреты\Ext\Module.bsl"
    $moduleSource = Get-Content -Raw -LiteralPath $moduleSourcePath -Encoding UTF8
    if ($moduleSource -notmatch 'УстановитьПривилегированныйРежим\(Истина\)' -or
        $moduleSource -notmatch 'УстановитьПривилегированныйРежим\(ИсходныйРежим\)') {
        throw "AI_MCPСекреты must bracket secret storage access with a restored privileged mode."
    }
}

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
Assert-KnowledgeBundleHelpRegistration
Assert-McpSecretAccessContract
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
    $knowledgeBundleResult = @(
        $resultLines | Where-Object { $_ -like "PASS|knowledge_bundles|*" }
    )
    if ($knowledgeBundleResult.Count -ne 1) {
        throw "Knowledge bundles test did not run exactly once. See $resultFile"
    }
    $mcpResult = @($resultLines | Where-Object { $_ -like "PASS|mcp_integration|*" })
    if ($mcpResult.Count -ne 1) {
        throw "MCP integration test did not run exactly once. See $resultFile"
    }
} finally {
    if ($ownsMockProcess -and $mockProcess -and -not $mockProcess.HasExited) {
        Stop-Process -Id $mockProcess.Id -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "[OK] Functional smoke tests passed."
