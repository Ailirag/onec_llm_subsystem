<#
.SYNOPSIS
Пишет артефакт с изменёнными объектами метаданных для адресного прогона Web UI.

.DESCRIPTION
Заменяет карту «изменённый объект → каталог тестов» выводом из выгрузки. Карта
задавала цель путём, поэтому её точность упиралась в каталог: правка одного отчёта
требовала прогона всех отчётов. Здесь цель выводится из объекта.

Артефакт читают:

- тест `00-interface/03-changed-objects.test.mjs` — открывает каждый объект
  навигационной ссылкой и проверяет отсутствие ошибок;
- отбор объёма прогона — строит из синонимов выражение имён для `--grep`, чтобы из
  параметризованных проверок выполнялись только относящиеся к изменённым объектам.

Синоним берётся из самой выгрузки, то есть то же значение, которое видит
пользователь. Хардкода соответствий нет.

.PARAMETER BaseRef
База сравнения. Пусто — берётся из политики актуализации тестов.

.PARAMETER OutputPath
Куда писать артефакт. Пусто — `<localStateDir>/changed-ui-targets.json`.
#>
[CmdletBinding()]
param(
    [string]$BaseRef = "",
    [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Workflow.Common.ps1")

$repositoryRoot = Get-WorkflowRepositoryRoot -StartPath $PSScriptRoot
$config = Get-WorkflowConfig -RepositoryRoot $repositoryRoot
$stateDirectory = Resolve-WorkflowPath -RepositoryRoot $repositoryRoot -Path ([string]$config.localStateDir)

if (-not $BaseRef) {
    $maintenanceConfig = Get-WorkflowSettingValue -Object $config -Name "testMaintenance" -Default $null
    $policyPath = if ($null -ne $maintenanceConfig) {
        [string](Get-WorkflowSettingValue -Object $maintenanceConfig -Name "policy" -Default "")
    }
    else {
        ""
    }
    if ($policyPath) {
        $resolvedPolicy = Resolve-WorkflowPath -RepositoryRoot $repositoryRoot -Path $policyPath
        if (Test-Path -LiteralPath $resolvedPolicy -PathType Leaf) {
            $policy = Get-Content -Raw -LiteralPath $resolvedPolicy -Encoding UTF8 | ConvertFrom-Json
            $BaseRef = [string](Get-WorkflowSettingValue -Object $policy -Name "baseRef" -Default "")
        }
    }
}
if (-not $BaseRef) {
    $BaseRef = "origin/$([string]$config.mainBranch)"
}

$baseCheck = Invoke-WorkflowGit `
    -RepositoryRoot $repositoryRoot `
    -Arguments @("rev-parse", "--verify", $BaseRef) `
    -AllowFailure
if ($baseCheck.ExitCode -ne 0) {
    throw "Base ref was not found: $BaseRef. Fetch the repository first."
}

if (-not $OutputPath) {
    $OutputPath = Join-Path $stateDirectory "changed-ui-targets.json"
}

$changedPaths = @(Get-WorkflowChangedPaths -RepositoryRoot $repositoryRoot -BaseRef $BaseRef)
# Обёртка @() обязательна: возврат массива из функции разворачивается в скаляр при
# одном элементе, и при Set-StrictMode обращение к .Count падает.
$targets = @(
    Get-WorkflowChangedUiTargets `
        -RepositoryRoot $repositoryRoot `
        -Config $config `
        -ChangedPaths $changedPaths
)

# Пишется ОБЪЕКТ с полем targets, а не массив. ConvertTo-Json от пустого массива в
# PowerShell даёт пустую строку, то есть файл с расширением .json оказывается
# невалидным JSON. Тогда «изменений нет» и «артефакт испорчен» становятся
# неразличимы: читающая сторона в обоих случаях получает ошибку разбора и, если она
# её проглатывает, отчитывается «проверять нечего» — ложный зелёный.
$artifact = [pscustomobject]@{
    baseRef = $BaseRef
    changedPathCount = $changedPaths.Count
    targets = @($targets)
    generatedAt = [DateTimeOffset]::Now.ToString("o")
}
Write-WorkflowJson -Value $artifact -Path $OutputPath | Out-Null

Write-Host "База сравнения: $BaseRef"
Write-Host "Изменённых путей: $($changedPaths.Count)"
Write-Host "Объектов интерфейса: $($targets.Count)"
foreach ($target in $targets) {
    $synonym = if ($target.synonym) { $target.synonym } else { "(синоним не найден)" }
    Write-Host "  $($target.link) — $synonym"
}
Write-Host "Артефакт: $OutputPath"
