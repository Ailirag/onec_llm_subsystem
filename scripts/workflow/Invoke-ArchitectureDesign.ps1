[CmdletBinding()]
param(
    # Что предстоит сделать, одной-двумя фразами. Без этого архитектору нечего
    # обсуждать: правки ещё нет, и вывести задачу из кода невозможно.
    [string]$Task = "",

    # Только собрать пакет и показать путь. Нужно, когда архитектора зовут руками.
    [switch]$PacketOnly,

    # Позвать архитектора даже на простом маршруте.
    [switch]$Force
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "Workflow.Common.ps1")

<#
Замысел правки до кода.

Зачем отдельный этап. Ревью отвечает на вопрос «правильно ли это написано» и
приходит, когда код уже есть. Вопрос «нужно ли это делать и где этому место» к
тому времени решён, и замечание по нему означает переделку, а не правку.

Почему независимый сеанс. Автор только что придумал решение и читает задачу как
его обоснование. Поэтому архитектор получает ТОЛЬКО задачу, признаки маршрута и
состав конфигурации рядом с будущей правкой — и не получает решения автора.

Что здесь НЕ делается. Черновик архитектора замыслом не является: решение
принимает автор. Поэтому черновик приходит с открытыми вопросами, и пока на них
не ответили, Verify считает замысел незавершённым. Сгенерированный текст, который
сам себя засчитывает, превратил бы требование в штамп.
#>

$repositoryRoot = Get-WorkflowRepositoryRoot -StartPath $PSScriptRoot
$config = Get-WorkflowConfig -RepositoryRoot $repositoryRoot
$stateDirectory = Resolve-WorkflowPath -RepositoryRoot $repositoryRoot -Path ([string]$config.localStateDir)
$branchName = Get-WorkflowBranchName -RepositoryRoot $repositoryRoot
$baseRef = "origin/$([string]$config.mainBranch)"

$route = Get-WorkflowChangeRoute `
    -Config $config `
    -ChangedPaths (Get-WorkflowChangedPaths -RepositoryRoot $repositoryRoot -BaseRef $baseRef) `
    -AddedPaths (Get-WorkflowAddedPaths -RepositoryRoot $repositoryRoot -BaseRef $baseRef)

Write-Host "Маршрут: $($route.Route)"
foreach ($reason in @($route.Reasons)) {
    Write-Host "  $reason"
}

if ($route.Route -eq "простой" -and -not $Force) {
    Write-Host ""
    Write-Host "Простому маршруту замысел не нужен: правка идёт внутри существующей структуры."
    Write-Host "Позвать архитектора всё равно — ключ -Force."
    exit 0
}

$decisionPath = Get-WorkflowRouteDecisionPath `
    -RepositoryRoot $repositoryRoot `
    -Config $config `
    -BranchName $branchName

if ((Test-Path -LiteralPath $decisionPath -PathType Leaf) -and -not $Force) {
    Write-Host ""
    Write-Host "Замысел уже есть: $decisionPath"
    Write-Host "Переписать его заново — ключ -Force."
    exit 0
}

if (-not $Task) {
    throw ("Архитектору нужна задача: -Task ""<что предстоит сделать>"". Правки ещё нет, " +
        "и вывести задачу из кода невозможно — в этом и смысл этапа: он идёт до кода.")
}

# ── Пакет ─────────────────────────────────────────────────────────────────────
# Архитектор получает задачу, признаки маршрута и состав конфигурации рядом:
# решение «где этому место» без знания соседей выродится в совет общего вида.
$designDirectory = Join-Path (Join-Path $stateDirectory "design") (
    ($branchName -replace "[^A-Za-z0-9А-Яа-яЁё_-]+", "-").Trim("-"))
[System.IO.Directory]::CreateDirectory($designDirectory) | Out-Null
$packetPath = Join-Path $designDirectory "packet.md"

$sourceDirectory = Resolve-WorkflowPath -RepositoryRoot $repositoryRoot -Path ([string]$config.sourceDir)
$neighbours = New-Object System.Collections.ArrayList
foreach ($kind in @("Catalogs", "Documents", "InformationRegisters", "AccumulationRegisters", "ScheduledJobs")) {
    $kindPath = Join-Path $sourceDirectory $kind
    if (-not (Test-Path -LiteralPath $kindPath -PathType Container)) {
        continue
    }
    $names = @(
        Get-ChildItem -LiteralPath $kindPath -Filter "*.xml" -File -ErrorAction SilentlyContinue |
            Sort-Object Name |
            ForEach-Object { $_.BaseName }
    )
    if ($names.Count -eq 0) {
        continue
    }
    [void]$neighbours.Add("- $kind ($($names.Count)): $((@($names | Select-Object -First 25)) -join ', ')" +
        $(if ($names.Count -gt 25) { " …" } else { "" }))
}

$lines = New-Object System.Collections.ArrayList
[void]$lines.Add("# Замысел правки: пакет для архитектора")
[void]$lines.Add("")
[void]$lines.Add("## Задача")
[void]$lines.Add("")
[void]$lines.Add($Task)
[void]$lines.Add("")
[void]$lines.Add("## Почему маршрут сложный")
[void]$lines.Add("")
foreach ($reason in @($route.Reasons)) {
    [void]$lines.Add("- $reason")
}
if (@($route.Reasons).Count -eq 0) {
    [void]$lines.Add("- маршрут поднят вручную ключом -Force")
}
[void]$lines.Add("")
[void]$lines.Add("## Что уже есть в конфигурации")
[void]$lines.Add("")
foreach ($line in @($neighbours)) {
    [void]$lines.Add($line)
}
[void]$lines.Add("")
[void]$lines.Add("## Правила этой конфигурации")
[void]$lines.Add("")
[void]$lines.Add("Общие правила — `docs/rules/`, уточнения проекта — `docs/rules/project/`.")
[void]$lines.Add("Читай их перед ответом: порядок блокировок, префикс объектов и состав ПДн")
[void]$lines.Add("задаются проектом, и решение, им противоречащее, будет отвергнуто.")
[void]$lines.Add("")
[void]$lines.Add("## Что записать")
[void]$lines.Add("")
[void]$lines.Add("Запиши черновик замысла в файл (UTF-8):")
[void]$lines.Add("")
[void]$lines.Add("    $decisionPath")
[void]$lines.Add("")
[void]$lines.Add("Структура: что решено; какие варианты рассмотрены и почему отвергнуты;")
[void]$lines.Add("что это ломает у соседей; чего решение НЕ делает.")
[void]$lines.Add("")
[void]$lines.Add("Раздел «Вопросы автору» обязателен, и вопросы в нём — настоящие:")
[void]$lines.Add("то, чего из задачи и кода не видно, а решить нужно. Формат — `- [ ] вопрос`.")
[void]$lines.Add("Пока хоть один вопрос не отвечен, Verify считает замысел черновым:")
[void]$lines.Add("сгенерированный текст, который сам себя засчитывает, — это штамп, а не решение.")

Set-Content -LiteralPath $packetPath -Value ($lines -join [System.Environment]::NewLine) -Encoding UTF8
Write-Host ""
Write-Host "Пакет архитектора: $packetPath"

if ($PacketOnly) {
    Write-Host "Замысел ожидается здесь: $decisionPath"
    exit 0
}

# ── Запуск архитектора ────────────────────────────────────────────────────────
# Тот же механизм, что зовёт ревьюера: отдельный сеанс того же агента и той же
# модели, без привязки к сеансу автора. Разница между ними — только в задании.
$reviewConfig = Get-WorkflowSettingValue -Object $config -Name "review" -Default $null
$agent = Get-WorkflowDevelopmentAgent
$prompt = "Ты архитектор. Прочитай пакет {packet}, реши задачу по существу и запиши " +
    "черновик замысла в $decisionPath строго в описанной там структуре. Код не пиши и не правь: " +
    "на этом этапе решается, нужно ли делать и где этому место."
$designer = Resolve-WorkflowReviewCommand -ReviewConfig $reviewConfig -Agent $agent -Prompt $prompt

if ($null -eq $designer) {
    Write-Host ""
    Write-Host "Агент для архитектора не распознан, пакет собран — позовите архитектора руками."
    Write-Host "Замысел ожидается здесь: $decisionPath"
    exit 0
}

$modelText = if ($designer.Model) { $designer.Model } else { "умолчание инструмента" }
Write-Host "Архитектор: $($designer.Source); агент $($designer.Agent), модель $modelText"

$arguments = @(
    $designer.Command | ForEach-Object {
        ([string]$_).Replace("{packet}", $packetPath).Replace("{root}", $repositoryRoot)
    }
)
$executable = $arguments[0]
$rest = @()
if ($arguments.Count -gt 1) {
    $rest = $arguments[1..($arguments.Count - 1)]
}

$sessionVariables = @(Get-WorkflowAgentSessionVariables)
$saved = @{}
foreach ($name in $sessionVariables) {
    $saved[$name] = [System.Environment]::GetEnvironmentVariable($name)
    if ($null -ne $saved[$name]) {
        [System.Environment]::SetEnvironmentVariable($name, $null)
    }
}

try {
    $output = & $executable @rest 2>&1
    $exitCode = $LASTEXITCODE
}
finally {
    foreach ($name in $sessionVariables) {
        if ($null -ne $saved[$name]) {
            [System.Environment]::SetEnvironmentVariable($name, $saved[$name])
        }
    }
}

$logPath = Join-Path $designDirectory "architect.log"
Set-Content -LiteralPath $logPath -Value ((@($output) -join [System.Environment]::NewLine)) -Encoding UTF8

if ($exitCode -ne 0) {
    throw "Архитектор завершился с кодом ${exitCode}. Журнал: $logPath"
}
if (-not (Test-Path -LiteralPath $decisionPath -PathType Leaf)) {
    throw "Архитектор отработал, но замысел не появился: $decisionPath. Журнал: $logPath"
}

Write-Host ""
Write-Host "Черновик замысла: $decisionPath"

$open = @(Get-WorkflowDecisionOpenQuestions -Path $decisionPath)
if ($open.Count -gt 0) {
    Write-Host ""
    Write-Host "Вопросы автору — ответь в файле, отметив ответ вместо [ ]:"
    foreach ($question in $open) {
        Write-Host "  $question"
    }
    Write-Host ""
    Write-Host "Пока вопросы открыты, Verify считает замысел черновым: решение принимает автор,"
    Write-Host "а не сеанс, который его предложил."
}
