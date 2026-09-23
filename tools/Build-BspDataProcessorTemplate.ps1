[CmdletBinding()]
param(
    [string]$V8Path = "",
    [string]$InfoBasePath = "",
    [string]$UserName = "",
    [string]$Password = "",
    [string]$OutputFile = ""
)

# Собирает внешнюю обработку БСП из integrations/bsp и кладет результат
# в макет расширения DataProcessor.AI_ПомощникКонтекста.Template.ОбработкаБСП.
#
# Макет хранится в репозитории как двоичный файл, поэтому после любой правки
# исходников обработки этот скрипт надо прогонять заново, иначе в расширении
# останется устаревшая копия.

$ErrorActionPreference = "Stop"

$repositoryPath = Split-Path $PSScriptRoot -Parent
$sourceFile = Join-Path $repositoryPath "integrations\bsp\AI_ПомощникКонтекстаБСП.xml"
$templateFile = Join-Path $repositoryPath ("cfe llm\DataProcessors\AI_ПомощникКонтекста\Templates\" +
    "ОбработкаБСП\Ext\Template.bin")

if (-not (Test-Path -LiteralPath $sourceFile)) {
    throw "Не найдены исходники обработки: $sourceFile"
}
if (-not (Test-Path -LiteralPath (Split-Path $templateFile -Parent))) {
    throw "Не найден каталог макета. Сначала создайте макет ОбработкаБСП."
}

function Resolve-ProjectSetting {
    param([string]$Name)

    $registryPath = Join-Path $repositoryPath ".v8-project.json"
    if (-not (Test-Path -LiteralPath $registryPath)) {
        return ""
    }
    $registry = Get-Content -LiteralPath $registryPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($Name -eq "v8path") {
        return $registry.v8path
    }
    $database = $registry.databases | Where-Object { $_.id -eq $registry.default } | Select-Object -First 1
    if (-not $database) {
        return ""
    }
    return $database.$Name
}

if (-not $V8Path) {
    $V8Path = Resolve-ProjectSetting "v8path"
}
if (-not $InfoBasePath) {
    $InfoBasePath = Resolve-ProjectSetting "path"
}
if (-not $InfoBasePath) {
    throw "Не задана база для сборки. Передайте -InfoBasePath или заполните .v8-project.json."
}

if (-not $OutputFile) {
    $OutputFile = Join-Path $repositoryPath "build\AI_ПомощникКонтекстаБСП.epf"
}
New-Item -ItemType Directory -Path (Split-Path $OutputFile -Parent) -Force | Out-Null

$buildScript = Join-Path $env:USERPROFILE (
    ".claude\plugins\cache\cc-1c-skills\1c-skills\ccd860ae8998\.claude\skills\epf-build\scripts\epf-build.ps1")
if (-not (Test-Path -LiteralPath $buildScript)) {
    throw "Не найден скрипт сборки EPF из cc-1c-skills: $buildScript"
}

$arguments = @{
    SourceFile = $sourceFile
    OutputFile = $OutputFile
    InfoBasePath = $InfoBasePath
}
if ($V8Path) { $arguments.V8Path = $V8Path }
if ($UserName) { $arguments.UserName = $UserName }
if ($Password) { $arguments.Password = $Password }

& $buildScript @arguments
if ($LASTEXITCODE -ne 0) {
    throw "Сборка внешней обработки завершилась с кодом $LASTEXITCODE."
}
if (-not (Test-Path -LiteralPath $OutputFile)) {
    throw "Сборка не создала файл: $OutputFile"
}

Copy-Item -LiteralPath $OutputFile -Destination $templateFile -Force
$size = (Get-Item -LiteralPath $templateFile).Length

Write-Host ""
Write-Host "[OK] Макет обновлен из исходников обработки."
Write-Host "     Обработка: $OutputFile"
Write-Host "     Макет:     $templateFile ($size байт)"
Write-Host "     Не забудьте загрузить расширение в базу: /LoadConfigFromFiles -Extension LLM"
