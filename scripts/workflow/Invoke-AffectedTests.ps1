<#
.SYNOPSIS
Быстрый цикл разработчика: прогон только тех тестов, которые относятся к правкам.

.DESCRIPTION
Это ИНСТРУМЕНТ ОТЛАДКИ, а не гейт. Обязательные фазы `Finish` и `Review` всегда
гоняют регрессию ПОЛНОСТЬЮ на свежем стенде и заменять их этим скриптом нельзя:
изменение общего модуля или командного интерфейса ломает области, которые ни одна
карта соответствий не предскажет. Смысл скрипта — сократить цикл правка-проверка с
минут до десятков секунд, пока задача ещё в работе.

Экономия достигается двумя приёмами:

1. Выбор тестов. Карта «изменение → обязательные тесты» уже существует в политике
   актуализации тестов. Скрипт НЕ дублирует её разбор: он запускает
   `Test-TestMaintenance.ps1`, который эту карту уже применяет, и читает готовый
   отчёт. Так селектор и гейт не могут разойтись в трактовке правил.
2. Переиспользование стенда. Без `-RebuildStand` берётся постоянный стенд ветки,
   поэтому не платится основная цена прогона — создание базы, полная загрузка
   конфигурации, UpdateDBCfg и seed.

Если хотя бы одно затронутое правило требует сьют целиком, будет прогнан весь
сьют — и скрипт об этом скажет. Это сигнал, что правило в политике слишком
широкое: чем точнее карта, тем короче цикл.

.PARAMETER BaseRef
База сравнения. По умолчанию берётся из политики.

.PARAMETER DryRun
Только показать, что было бы запущено, и почему.

.PARAMETER RebuildStand
Пересоздать стенд перед прогоном. Нужно, если предыдущий прогон оставил данные
изменёнными и тесты не идемпотентны.

.PARAMETER Tags
Дополнительно сузить отбор тегами сьюта.
#>
[CmdletBinding()]
param(
    [string]$BaseRef = "",
    [switch]$DryRun,
    [switch]$RebuildStand,
    [string[]]$Tags = @()
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Workflow.Common.ps1")

$repositoryRoot = Get-WorkflowRepositoryRoot -StartPath $PSScriptRoot
$config = Get-WorkflowConfig -RepositoryRoot $repositoryRoot

# Отбор считает общая функция: тем же кодом пользуются фазы, когда объём прогона
# задан как affected+smoke. Две копии логики отбора неизбежно разошлись бы, и
# быстрый цикл начал бы проверять не то, что проверяет фаза.
$selection = Get-WorkflowAffectedSuiteTargets `
    -RepositoryRoot $repositoryRoot `
    -Config $config `
    -BaseRef $BaseRef

$impactedRules = @($selection.ImpactedRules)
if ($impactedRules.Count -eq 0) {
    Write-Host "Изменений в компонентах 1С нет — выбирать нечего."
    Write-Host "Для проверки инфраструктуры запустите scripts\ci\Invoke-Gate.ps1."
    return
}

$suiteTargets = New-Object System.Collections.ArrayList
foreach ($target in @($selection.Targets)) {
    [void]$suiteTargets.Add($target)
}
$outsideSuite = @($selection.OutsideSuite)

Write-Host "Затронутые правила политики:"
foreach ($rule in $impactedRules) {
    Write-Host "  $($rule.id) — изменено путей: $(@($rule.impactedPaths).Count)"
}
Write-Host ""

if ($selection.WholeSuite) {
    Write-Host "Правила требуют сьют ЦЕЛИКОМ: $(@($selection.WholeSuiteRules) -join ', ')."
    Write-Host "Выборка вырождается в полный прогон. Это признак слишком широкого"
    Write-Host "правила в политике: чем точнее карта, тем короче цикл разработчика."
}

if ($outsideSuite.Count -gt 0) {
    Write-Host ""
    Write-Host "Вне сьюта Web UI затронуто (этим скриптом НЕ запускается):"
    foreach ($item in $outsideSuite) {
        Write-Host "  $item"
    }
    Write-Host "Функциональный контур проверяйте фазой Finish или его скриптами напрямую."
}

if ($suiteTargets.Count -eq 0) {
    Write-Host ""
    Write-Host "В сьюте Web UI нечего запускать для этих изменений."
    return
}

Write-Host ""
Write-Host "К запуску:"
foreach ($target in $suiteTargets) {
    Write-Host "  $target"
}

if ($DryRun) {
    Write-Host ""
    Write-Host "-DryRun: прогон не выполнялся."
    return
}

# ── 3. Прогон на постоянном стенде ветки ─────────────────────────────────────
$webUiConfig = Get-WorkflowSettingValue -Object $config -Name "webUiTests" -Default $null
$webUiScript = Resolve-WorkflowPath -RepositoryRoot $repositoryRoot -Path ([string]$webUiConfig.script)
$failures = New-Object System.Collections.ArrayList
$rebuildRemaining = [bool]$RebuildStand

foreach ($target in $suiteTargets) {
    Write-Host ""
    Write-Host "==> $target"
    $arguments = @("-TestPath", $target)
    if ($Tags.Count -gt 0) {
        $arguments += @("-Tags", ($Tags -join ','))
    }
    # Пересоздаём стенд только перед первой целью: дальше он уже пригоден, а
    # повторное пересоздание съело бы весь смысл быстрого цикла.
    if ($rebuildRemaining) {
        $arguments += "-RebuildStand"
        $rebuildRemaining = $false
    }

    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $webUiScript @arguments
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorAction
    }
    if ($exitCode -ne 0) {
        [void]$failures.Add($target)
    }
}

Write-Host ""
if ($failures.Count -gt 0) {
    throw "Выборочный прогон завершился с ошибками: $($failures -join ', ')"
}
Write-Host "Выборочный прогон пройден. ЭТО НЕ ЗАМЕНА фазам Selfcheck и Verify:"
Write-Host "они гоняют регрессию полностью и на свежем стенде."
