<#
.SYNOPSIS
    Собирает иллюстрированную инструкцию, прокликивая сценарий в веб-клиенте.

.DESCRIPTION
    Этап dev-flow, вызываемый вручную: он ходит в базу, обращается к модели и
    занимает минуты, поэтому в обычный прогон тестов не входит.

    Сценарий исполняет тот же раннер, что и UI-тесты, — значит поиск элементов
    и подсветка уже решены и не дублируются. Сценарий сам снимает экраны,
    дорисовывает стрелку с курсором и собирает HTML.

    Контекст раннера не дает сценарию ни аргументов, ни переменных окружения,
    поэтому скрипт подставляет перед текстом сценария две константы: ВЫХОД —
    каталог вывода — и ПАРАМЕТРЫ — значения из -Parameters и флаг записывать.

    По умолчанию сборка ничего не записывает в базу: шаг, который записывает
    данные, снимается с указателем, но кнопка не нажимается. -ApplyResults
    нажимает и ее — только на тестовом стенде.

.PARAMETER Parameters
    Имена, которые зависят от базы: список, документы, подпись действия.
    Ключи — у каждого сценария свои, см. его начало; по умолчанию сценарии
    настроены на демонстрационный стенд Документооборота.

.PARAMETER ApplyResults
    Выполнять шаги, которые записывают данные в базу.

.EXAMPLE
    tools\Build-UserGuide.ps1 -Url http://localhost:8081/do21 -Scenario contract-fill

.EXAMPLE
    tools\Build-UserGuide.ps1 -Scenario batch-queue -Parameters @{ 'документы' = @('ПСТ-2026/417', 'ПСТ-2026/418') }
#>
[CmdletBinding()]
param(
    [string]$Url = "http://localhost:8081/do21",
    [string]$Scenario = "contract-fill",
    [string]$OutputRoot = "",
    [string]$WebTestRunner = "",
    [hashtable]$Parameters = @{},
    [switch]$ApplyResults
)

$ErrorActionPreference = "Stop"

$repositoryPath = Split-Path $PSScriptRoot -Parent
if ($Scenario.StartsWith("_")) {
    throw "Файл на подчеркивание — это библиотека сборщика, а не сценарий: $Scenario"
}
$scenarioFile = Join-Path $repositoryPath "tests\ui\guides\$Scenario.mjs"
if (-not (Test-Path -LiteralPath $scenarioFile -PathType Leaf)) {
    throw "Сценарий не найден: $scenarioFile"
}

if (-not $OutputRoot) {
    $OutputRoot = Join-Path $repositoryPath "build\guides"
}
$outputDirectory = Join-Path $OutputRoot $Scenario
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
Get-ChildItem -LiteralPath $outputDirectory -File -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

. (Join-Path $PSScriptRoot "WebTestRunner.ps1")
$WebTestRunner = Find-WebTestRunner -Path $WebTestRunner

try {
    $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 10
    if ($response.StatusCode -ne 200) { throw "HTTP $($response.StatusCode)" }
} catch {
    throw "Публикация недоступна: $Url. Опубликуйте базу перед сборкой инструкции."
}

Install-WebTestRunnerDependencies -Runner $WebTestRunner

# Каталог уходит в сценарий строкой JS: в пути Windows есть обратные слеши.
$outputLiteral = $outputDirectory.Replace('\', '\\')
$scenarioParameters = @{}
foreach ($key in $Parameters.Keys) {
    $scenarioParameters[[string]$key] = $Parameters[$key]
}
$scenarioParameters["записывать"] = [bool]$ApplyResults
$parametersLiteral = ConvertTo-Json -InputObject $scenarioParameters -Compress -Depth 5
$prologue = "const ВЫХОД = `"$outputLiteral`";" + [Environment]::NewLine +
    "const ПАРАМЕТРЫ = $parametersLiteral;"

# Механика снимков общая для всех сценариев и подставляется перед текстом
# сценария: раннер исполняет файл как тело функции, импортов там нет, а
# копировать полсотни строк в каждую инструкцию — верный способ развести их.
$runtimeFile = Join-Path (Split-Path $scenarioFile -Parent) "_runtime.mjs"
if (Test-Path -LiteralPath $runtimeFile -PathType Leaf) {
    $prologue = $prologue + [Environment]::NewLine +
        [System.IO.File]::ReadAllText($runtimeFile, [System.Text.UTF8Encoding]::new($false))
}

$scenarioBody = [System.IO.File]::ReadAllText($scenarioFile, [System.Text.UTF8Encoding]::new($false))
$prepared = Join-Path $env:TEMP ("web-test-guide-" + [guid]::NewGuid().ToString("N") + ".mjs")
[System.IO.File]::WriteAllText($prepared, $prologue + "`n" + $scenarioBody, [System.Text.UTF8Encoding]::new($false))

Write-Host "Сценарий:  $Scenario"
Write-Host "База:      $Url"
Write-Host "Вывод:     $outputDirectory"
Write-Host "Параметры: $parametersLiteral"
if ($ApplyResults) {
    Write-Host "Запись:    шаги, которые записывают данные в базу, будут выполнены"
} else {
    Write-Host "Запись:    нет — шаг записи снимается без нажатия кнопки"
}
Write-Host ""

try {
    & node $WebTestRunner run $Url $prepared
    $exitCode = $LASTEXITCODE
} finally {
    Remove-Item -LiteralPath $prepared -Force -ErrorAction SilentlyContinue
}

if ($exitCode -ne 0) {
    throw "Сборка инструкции не удалась. Снимок ошибки лежит рядом с раннером."
}

$indexFile = Join-Path $outputDirectory "index.html"
if (-not (Test-Path -LiteralPath $indexFile -PathType Leaf)) {
    throw "Сценарий отработал, но не создал index.html."
}

$size = (Get-Item -LiteralPath $indexFile).Length
Write-Host ""
Write-Host ("[OK] Инструкция собрана: {0} ({1:N0} байт)" -f $indexFile, $size)
