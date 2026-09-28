[CmdletBinding()]
param(
    [string]$BaseRef = "",
    [string]$ReportPath = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Workflow.Common.ps1")

$repositoryRoot = Get-WorkflowRepositoryRoot -StartPath $PSScriptRoot
$config = Get-WorkflowConfig -RepositoryRoot $repositoryRoot
if (
    $null -eq $config.PSObject.Properties["testMaintenance"] -or
    $null -eq $config.testMaintenance -or
    -not [bool]$config.testMaintenance.enabled
) {
    Write-Host "Test maintenance policy is disabled."
    return
}

$policyPath = Resolve-WorkflowPath `
    -RepositoryRoot $repositoryRoot `
    -Path ([string]$config.testMaintenance.policy)
$policy = Get-Content -Raw -Encoding UTF8 -LiteralPath $policyPath | ConvertFrom-Json
if ([int]$policy.schemaVersion -ne 1) {
    throw "Unsupported test maintenance policy schema: $($policy.schemaVersion)"
}
if (-not $BaseRef) {
    $BaseRef = [string]$policy.baseRef
}
$componentSourcePattern = Get-WorkflowComponentSourcePattern -RepositoryRoot $repositoryRoot -Config $config

# Корень Web UI сьюта подставляется из настроек проекта, а не пишется в политике.
# Зашитый путь делает правило недостижимым: проект, у которого сьют лежит не там,
# получает требование «обнови проверку в каталоге X», где ни один тест не
# запускается, — то есть требование, которое нечем выполнить. Обнаружено на живом
# проекте: политика требовала правку в tests/web-ui, а прогонялся
# tests/<проект>, и обновление карты разделов правилу не засчитывалось.
$webUiSuitePattern = "tests/web-ui"
if ($null -ne $config.PSObject.Properties["webUiTests"] -and
    $null -ne $config.webUiTests -and
    [string]$config.webUiTests.suite) {
    $webUiSuitePattern = ([string]$config.webUiTests.suite).Replace('\', '/').Trim('/')
}

$expandPattern = {
    param([string]$Pattern)

    Expand-WorkflowPolicyPattern -Pattern $Pattern `
        -ComponentPattern $componentSourcePattern `
        -WebUiSuite $webUiSuitePattern
}

$baseCheck = Invoke-WorkflowGit `
    -RepositoryRoot $repositoryRoot `
    -Arguments @("rev-parse", "--verify", $BaseRef) `
    -AllowFailure
if ($baseCheck.ExitCode -ne 0) {
    throw "Test maintenance base ref was not found: $BaseRef. Fetch the repository first."
}

$changedPaths = Get-WorkflowChangedPaths -RepositoryRoot $repositoryRoot -BaseRef $BaseRef

$ruleResults = @()
$violations = @()
foreach ($rule in @($policy.rules)) {
    $changePatterns = @(
        $rule.changePatterns | ForEach-Object { & $expandPattern $_ }
    )
    $requiredPatterns = @(
        $rule.requiredTestPatterns | Where-Object { $_ } |
            ForEach-Object { & $expandPattern $_ }
    )
    $impactedPaths = @(
        $changedPaths |
            Where-Object {
                $candidate = $_
                @($changePatterns | Where-Object { $candidate -match $_ }).Count -gt 0
            }
    )
    if ($impactedPaths.Count -eq 0) {
        continue
    }

    # Отложенный сценарий доказательством не считается. Иначе политику обходили бы
    # одним движением: положил файл в `pending`, правило зачлось, а в обязательный
    # объём проверка так и не попала — и это выглядело бы как соблюдённое правило.
    $testEvidence = @(
        $changedPaths |
            Where-Object {
                $candidate = $_
                (
                    @($requiredPatterns | Where-Object { $candidate -match $_ }).Count -gt 0 -and
                    -not (Test-WorkflowPendingSuitePath -Path $candidate)
                )
            }
    )
    # Правило без requiredTestPatterns НЕ требует от автора ничего: оно существует,
    # чтобы назначить объём прогона. Так описывается покрытие, которое обеспечивает
    # адаптивная проверка: сценарий открытия изменённых объектов читает diff и сам
    # не меняется, поэтому требовать его правку значит требовать правку ради правки.
    #
    # Раньше такое правило было невыполнимым: доказательств нет никогда, и отказ
    # приходил на любом добавлении объекта метаданных. Обходили бы его пустой
    # правкой соседнего теста — то есть ровно тем, ради предотвращения чего
    # политика и заводилась.
    $requiresAuthorUpdate = $requiredPatterns.Count -gt 0
    $success = (-not $requiresAuthorUpdate) -or ($testEvidence.Count -gt 0)
    $result = [pscustomobject]@{
        id = [string]$rule.id
        description = [string]$rule.description
        success = $success
        impactedPaths = $impactedPaths
        testEvidence = $testEvidence
        requiredTestPatterns = @($requiredPatterns)
        # Что ПРОГОНЯТЬ, когда правило сработало. Это не то же самое, что автор
        # обязан обновить. Правка формы обязывает автора обновить какую-нибудь
        # UI-проверку — любую из каталога, — но прогонять надо адресный сценарий,
        # который открывает именно изменённые объекты. Пока поле было одно,
        # требование «обнови что-нибудь в каталоге» разворачивалось в «прогони
        # весь каталог»: правка одной формы открывала полсотни чужих команд.
        #
        # Не задано — прогоняется то же, что требуется обновить: прежнее поведение.
        runTestPatterns = @(
            @(Get-WorkflowSettingValue -Object $rule -Name "runTestPatterns" -Default $rule.requiredTestPatterns) |
                Where-Object { $_ } |
                ForEach-Object { & $expandPattern $_ }
        )
        effectiveChangePatterns = $changePatterns
    }
    $ruleResults += $result
    if (-not $success) {
        $violations += $result
    }
}

$testFiles = @()
$webUiEnabled = (
    $null -ne $config.PSObject.Properties["webUiTests"] -and
    $null -ne $config.webUiTests -and
    [bool]$config.webUiTests.enabled
)
if ($webUiEnabled -and [string]$config.webUiTests.suite) {
    $suitePath = Resolve-WorkflowPath `
        -RepositoryRoot $repositoryRoot `
        -Path ([string]$config.webUiTests.suite)
    if (Test-Path -LiteralPath $suitePath -PathType Container) {
        $testFiles = @(
            Get-ChildItem -LiteralPath $suitePath -Filter "*.test.mjs" -File -Recurse
        )
    }
}
$hygieneViolations = @()
foreach ($testFile in $testFiles) {
    $content = Get-Content -Raw -Encoding UTF8 -LiteralPath $testFile.FullName
    $relativePath = $testFile.FullName.Substring(
        $repositoryRoot.TrimEnd('\').Length + 1
    ).Replace('\', '/')

    if ($content -match 'export\s+const\s+only\s*=\s*true') {
        $hygieneViolations += [pscustomobject]@{
            path = $relativePath
            message = "Debug-only export const only = true must not be committed."
        }
    }
    if (
        $content -match 'export\s+const\s+skip\s*=' -and
        $content -notmatch '(?i)([A-ZА-Я]{2,10}-\d+|#\d+)'
    ) {
        $hygieneViolations += [pscustomobject]@{
            path = $relativePath
            message = "A skipped test must contain a task or issue number."
        }
    }
}

if (-not $ReportPath) {
    $stateDirectory = Resolve-WorkflowPath `
        -RepositoryRoot $repositoryRoot `
        -Path ([string]$config.localStateDir)
    $timestamp = "$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')-$PID"
    $ReportPath = Join-Path $stateDirectory "reports\test-maintenance-$timestamp.json"
}

$report = [pscustomobject]@{
    operation = "test-maintenance"
    baseRef = $BaseRef
    success = $violations.Count -eq 0 -and $hygieneViolations.Count -eq 0
    changedPaths = $changedPaths
    rules = $ruleResults
    violations = $violations
    testFiles = $testFiles.Count
    hygieneViolations = $hygieneViolations
    completedAt = [DateTimeOffset]::Now.ToString("o")
}
Write-WorkflowJson -Value $report -Path $ReportPath | Out-Null
Write-Host "Test maintenance report: $([System.IO.Path]::GetFullPath($ReportPath))"

if ($violations.Count -gt 0 -or $hygieneViolations.Count -gt 0) {
    foreach ($violation in $violations) {
        Write-Host "MISSING TEST UPDATE [$($violation.id)]: $($violation.description)"
        $violation.impactedPaths | ForEach-Object { Write-Host "  changed: $_" }
        $violation.requiredTestPatterns | ForEach-Object { Write-Host "  expected: $_" }
    }
    foreach ($violation in $hygieneViolations) {
        Write-Host "INVALID TEST [$($violation.path)]: $($violation.message)"
    }
    throw "Test maintenance policy failed: $($violations.Count) missing update(s), $($hygieneViolations.Count) hygiene violation(s)."
}

Write-Host "Test maintenance policy passed."
