[CmdletBinding()]
param(
    [string]$V8Path = "",
    [string]$InfoBasePath = "",
    [string]$UserName = "",
    [string]$Password = "",
    [string]$OutputDirectory = ""
)

# Собирает внешние обработки, которые поставляются внутри расширения, и кладет
# каждую в свой макет DataProcessor.AI_ПомощникКонтекста:
#   ОбработкаБСП            <- integrations/bsp/AI_ПомощникКонтекстаБСП
#                              (команда помощника в карточках и списках БСП);
#   АдаптерДокументооборота <- integrations/do/AI_АдаптерДокументооборота
#                              (роли и автоподстановки исполнителей ДО).
# Администратор получает их из самой базы — командами «Сохранить обработку для
# БСП» и «Сохранить адаптер Документооборота», — собирать из исходников не нужно.
#
# Макеты хранятся в репозитории двоичными файлами, поэтому после любой правки
# исходников обработки этот скрипт надо прогонять заново, иначе в расширении
# останется устаревшая копия.

$ErrorActionPreference = "Stop"

$repositoryPath = Split-Path $PSScriptRoot -Parent
$templatesPath = Join-Path $repositoryPath "cfe llm\DataProcessors\AI_ПомощникКонтекста\Templates"
$processors = @(
    @{ Source = "integrations\bsp\AI_ПомощникКонтекстаБСП.xml"; Template = "ОбработкаБСП" },
    @{ Source = "integrations\do\AI_АдаптерДокументооборота.xml"; Template = "АдаптерДокументооборота" }
)

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
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $repositoryPath "build"
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

$buildScript = Join-Path $env:USERPROFILE (
    ".claude\plugins\cache\cc-1c-skills\1c-skills\ccd860ae8998\.claude\skills\epf-build\scripts\epf-build.ps1")
if (-not (Test-Path -LiteralPath $buildScript)) {
    throw "Не найден скрипт сборки EPF из cc-1c-skills: $buildScript"
}

Write-Host ""
foreach ($processor in $processors) {
    $sourceFile = Join-Path $repositoryPath $processor.Source
    $templateFile = Join-Path $templatesPath ($processor.Template + "\Ext\Template.bin")
    if (-not (Test-Path -LiteralPath $sourceFile)) {
        throw "Не найдены исходники обработки: $sourceFile"
    }
    if (-not (Test-Path -LiteralPath (Split-Path $templateFile -Parent))) {
        throw "Не найден каталог макета $($processor.Template). Сначала создайте макет."
    }

    $outputFile = Join-Path $OutputDirectory ([System.IO.Path]::GetFileNameWithoutExtension($sourceFile) + ".epf")
    $arguments = @{
        SourceFile = $sourceFile
        OutputFile = $outputFile
        InfoBasePath = $InfoBasePath
    }
    if ($V8Path) { $arguments.V8Path = $V8Path }
    if ($UserName) { $arguments.UserName = $UserName }
    if ($Password) { $arguments.Password = $Password }

    & $buildScript @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Сборка $($processor.Source) завершилась с кодом $LASTEXITCODE."
    }
    if (-not (Test-Path -LiteralPath $outputFile)) {
        throw "Сборка не создала файл: $outputFile"
    }

    Copy-Item -LiteralPath $outputFile -Destination $templateFile -Force
    $size = (Get-Item -LiteralPath $templateFile).Length
    Write-Host "[OK] Макет $($processor.Template) обновлен: $outputFile ($size байт)"
}

Write-Host ""
Write-Host "Не забудьте загрузить расширение в базу: /LoadConfigFromFiles -Extension LLM"
