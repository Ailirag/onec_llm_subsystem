<#
.SYNOPSIS
    Собирает иллюстрированную инструкцию, прокликивая сценарий в веб-клиенте.

.DESCRIPTION
    Этап dev-flow, вызываемый вручную: он ходит в реальную базу, обращается
    к модели и занимает минуты, поэтому в обычный прогон тестов не входит.

    Сценарий исполняет тот же раннер, что и UI-тесты, — значит поиск элементов
    и подсветка уже решены и не дублируются. Сценарий сам снимает экраны,
    дорисовывает стрелку с курсором и собирает HTML.

    Каталог вывода подставляется в сценарий переменной ВЫХОД: контекст раннера
    не дает сценарию ни аргументов, ни переменных окружения.

.EXAMPLE
    tools\Build-UserGuide.ps1 -Url http://localhost:8081/do21 -Scenario contract-fill
#>
[CmdletBinding()]
param(
    [string]$Url = "http://localhost:8081/do21",
    [string]$Scenario = "contract-fill",
    [string]$OutputRoot = "",
    [string]$WebTestRunner = ""
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
    throw "Раннер web-test из cc-1c-skills не найден. Установите плагин или передайте -WebTestRunner."
}

try {
    $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 10
    if ($response.StatusCode -ne 200) { throw "HTTP $($response.StatusCode)" }
} catch {
    throw "Публикация недоступна: $Url. Опубликуйте базу перед сборкой инструкции."
}

$runnerDirectory = Split-Path $WebTestRunner -Parent
if (-not (Test-Path -LiteralPath (Join-Path $runnerDirectory "node_modules"))) {
    & npm.cmd ci --prefix $runnerDirectory
    if ($LASTEXITCODE -ne 0) { throw "Не удалось поставить зависимости раннера." }
}

# Каталог уходит в сценарий строкой JS: в пути Windows есть обратные слеши.
$outputLiteral = $outputDirectory.Replace('\', '\\')
$prologue = "const ВЫХОД = `"$outputLiteral`";"

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

Write-Host "Сценарий: $Scenario"
Write-Host "База:     $Url"
Write-Host "Вывод:    $outputDirectory"
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
