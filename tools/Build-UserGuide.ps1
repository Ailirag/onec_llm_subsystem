<#
.SYNOPSIS
    Собирает пользовательскую инструкцию, прокликивая сценарий в веб-клиенте.

.DESCRIPTION
    Этап вызывается вручную и в обязательную последовательность фаз не входит:
    он работает с живым стендом, с настоящими данными и с внешними сервисами,
    которые может дёргать конфигурация. Ставить такое в Selfcheck нельзя.

    Смысл этапа в том, что инструкция снимается с работающей системы. Текстовое
    руководство расходится с интерфейсом на второй правке формы, и расхождение
    незаметно: читает его пользователь, а не автор. Здесь переставили кнопку —
    пересобрали, и на снимках новое расположение.

    Сценарий живёт в каталоге userGuides.scenarios и содержит только шаги.
    Механика — подсветка, стрелка, курсор, сборка HTML — приходит из
    guide-runtime.mjs, который подставляется перед текстом сценария.

    Стенд этап не поднимает: берётся тот же стенд ветки, что у регрессии Web UI.
    Публикация — дело tools\Publish-WebTestStand.ps1, и удваивать здесь подбор
    портов с межпроцессной блокировкой незачем.

.PARAMETER Scenario
    Имя файла сценария без расширения из каталога userGuides.scenarios.

.PARAMETER Url
    Адрес опубликованной базы. По умолчанию берётся стенд Web UI текущей ветки.

.PARAMETER OutputRoot
    Куда складывать результат. По умолчанию — userGuides.outputDir.

.EXAMPLE
    tools\Build-UserGuide.ps1 -Scenario contract-fill
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Scenario,

    [string]$Url = "",
    [string]$OutputRoot = "",
    [int]$Port = 0,
    [string]$AppName = ""
)

$ErrorActionPreference = "Stop"
$repositoryRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repositoryRoot "scripts\workflow\Workflow.Common.ps1")

$config = Get-WorkflowConfig -RepositoryRoot $repositoryRoot
$urlWasExplicit = -not [string]::IsNullOrWhiteSpace($Url)
# Раздела может не быть вовсе: проект поднялся с версии комплекта, где этапа
# ещё не было. Это не «выключено», это «не установлено», и лечится по-другому.
if ($null -eq $config.PSObject.Properties["userGuides"]) {
    throw "В .1c-workflow.json нет раздела userGuides. Поднимите комплект фазой KitUpdate."
}
if (-not [bool]$config.userGuides.enabled) {
    throw "Сборка инструкций выключена: userGuides.enabled в .1c-workflow.json."
}

$scenarioRoot = Resolve-WorkflowPath `
    -RepositoryRoot $repositoryRoot `
    -Path ([string]$config.userGuides.scenarios)
if (-not (Test-Path -LiteralPath $scenarioRoot -PathType Container)) {
    throw "Каталог сценариев инструкций не найден: $scenarioRoot"
}
$scenarioFile = Join-Path $scenarioRoot "$Scenario.mjs"
if (-not (Test-Path -LiteralPath $scenarioFile -PathType Leaf)) {
    $available = @(
        Get-ChildItem -LiteralPath $scenarioRoot -Filter "*.mjs" -File |
            Sort-Object Name |
            ForEach-Object { $_.BaseName }
    )
    $hint = if ($available.Count -gt 0) { " Доступны: $($available -join ', ')." } else { "" }
    throw "Сценарий инструкции не найден: $scenarioFile.$hint"
}

$library = Join-Path $PSScriptRoot "guide-runtime.mjs"
if (-not (Test-Path -LiteralPath $library -PathType Leaf)) {
    throw "Библиотека сборки инструкций не найдена: $library"
}

if (-not $OutputRoot) {
    $OutputRoot = [string]$config.userGuides.outputDir
}
$outputRootPath = Resolve-WorkflowPath -RepositoryRoot $repositoryRoot -Path $OutputRoot
$outputDirectory = Join-Path $outputRootPath $Scenario
[System.IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
# Чистится только содержимое своего подкаталога и только файлы: прошлый прогон
# мог снять больше шагов, и его снимки не должны попасть в новую инструкцию.
if (-not (Test-WorkflowPathUnderRoot -Path $outputDirectory -Root $outputRootPath)) {
    throw "Каталог вывода вне корня инструкций: $outputDirectory"
}
Get-ChildItem -LiteralPath $outputDirectory -File -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

if (-not $Url) {
    $standBranch = Get-WorkflowStandBranchName -RepositoryRoot $repositoryRoot
    if (-not $AppName) {
        $AppName = Get-WorkflowStandAppName `
            -Config $config `
            -BranchName $standBranch `
            -DefaultAppName ([string]$config.webUiTests.defaultAppName)
    }
    if ($Port -eq 0) {
        $Port = Get-WorkflowSavedStandPort `
            -RepositoryRoot $repositoryRoot `
            -Config $config `
            -Kind "web-ui" `
            -BranchName $standBranch
    }
    if ($Port -eq 0) {
        throw ("Стенд Web UI этой ветки не опубликован, адрес брать неоткуда. " +
            "Опубликуйте: tools\Publish-WebTestStand.ps1 — или передайте -Url.")
    }
    $Url = "http://localhost:$Port/$AppName"
}
elseif ($urlWasExplicit) {
    # Внешний адрес законен, а локальный сверяется с реестром текущей ветки.
    # Иначе старый Apache на соседнем порту честно ответит 200, и инструкция
    # незаметно снимется с базы, которую текущая ветка уже не обновляет.
    $explicitUri = $null
    if (-not [System.Uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$explicitUri)) {
        throw "Некорректный адрес публикации: $Url"
    }
    if ($explicitUri.IsLoopback) {
        $standBranch = Get-WorkflowStandBranchName -RepositoryRoot $repositoryRoot
        Assert-WorkflowGuideLocalUrlMatchesBranch `
            -Url $Url `
            -RepositoryRoot $repositoryRoot `
            -Config $config `
            -BranchName $standBranch
    }
}

# Проверка до запуска раннера: иначе отказ выглядит как падение браузера через
# полминуты после старта, и разбираются с ним не там, где он произошёл.
try {
    $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 15
    if ($response.StatusCode -ne 200) {
        throw "HTTP $($response.StatusCode)"
    }
}
catch {
    throw "Публикация недоступна: $Url. Опубликуйте стенд перед сборкой инструкции."
}

$stateDirectory = Resolve-WorkflowPath `
    -RepositoryRoot $repositoryRoot `
    -Path ([string]$config.localStateDir)
$ccRoot = Resolve-Cc1CSkillsRoot -Config $config
$webTestRuntime = Initialize-WorkflowWebTestRuntime `
    -Cc1CSkillsRoot $ccRoot `
    -StateDirectory $stateDirectory
$staleBrowsers = @(Get-WorkflowStaleBrowserProcesses -BrowsersPath $webTestRuntime.BrowsersPath)
if ($staleBrowsers.Count -gt 0) {
    $processIds = @($staleBrowsers | ForEach-Object { $_.Id }) -join ", "
    Write-Warning ("Остались процессы Chromium от прежнего прогона (PID: $processIds). " +
        "Они могут помешать новому окну развернуться; закройте их, если кадр не проходит minWidth.")
}

Write-Host "Сценарий: $Scenario"
Write-Host "База:     $Url"
Write-Host "Вывод:    $outputDirectory"
Write-Host ""

try {
    # Каталог вывода уходит в сценарий строкой JS, а в пути Windows есть обратные
    # слеши: без удвоения библиотека получит управляющие последовательности.
    # Настройки снимка едут в рантайм подстановкой: сценарий исполняется как тело
    # функции, и прочитать манифест оттуда нечем. Ужимать снимки на месте съёмки
    # обязательно — инструкция самодостаточна, картинки лежат в ней строкой
    # data:, и каждый килобайт растёт на треть от кодирования.
    $shotSettings = Get-WorkflowSettingValue -Object $config.userGuides -Name "screenshot" -Default $null
    $shotFormat = [string](Get-WorkflowSettingValue -Object $shotSettings -Name "format" -Default "png")
    $shotQuality = [string](Get-WorkflowSettingValue -Object $shotSettings -Name "quality" -Default 72)
    $shotScale = [string](Get-WorkflowSettingValue -Object $shotSettings -Name "scale" -Default "css")
    $shotMinWidth = [int](Get-WorkflowSettingValue -Object $shotSettings -Name "minWidth" -Default 1280)
    # Приведение к строке ДО вызова метода. В записи [string](...).ToLowerInvariant()
    # приведение относится ко всему выражению, и метод зовётся у Boolean —
    # этап падал на первой же сборке, а поймать это можно было только живым
    # запуском: подстановка настроек проверялась по тексту скрипта.
    $shotKeepFiles = ([bool](Get-WorkflowSettingValue -Object $shotSettings -Name "keepFiles" -Default $false)).ToString().ToLowerInvariant()

    $prepared = @(
        (Get-Content -Raw -LiteralPath $library -Encoding UTF8).
            Replace("__GUIDE_OUTPUT__", $outputDirectory.Replace('\', '\\')).
            Replace("__GUIDE_IMAGE_FORMAT__", $shotFormat).
            Replace("__GUIDE_IMAGE_QUALITY__", $shotQuality).
            Replace("__GUIDE_IMAGE_SCALE__", $shotScale).
            Replace("__GUIDE_MIN_WIDTH__", [string]$shotMinWidth).
            Replace("__GUIDE_KEEP_FILES__", $shotKeepFiles),
        (Get-Content -Raw -LiteralPath $scenarioFile -Encoding UTF8)
    ) -join [Environment]::NewLine

    $runDirectory = Join-Path $stateDirectory "guides"
    [System.IO.Directory]::CreateDirectory($runDirectory) | Out-Null
    $preparedFile = Join-Path $runDirectory "$Scenario-$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')-$PID.mjs"
    # Без BOM: раннер исполняет файл как тело функции, и метка порядка байтов
    # превращается в синтаксическую ошибку на первой строке.
    [System.IO.File]::WriteAllText($preparedFile, $prepared, [System.Text.UTF8Encoding]::new($false))

    & node.exe $webTestRuntime.Runner run $Url $preparedFile
    if ($LASTEXITCODE -ne 0) {
        throw "Сборка инструкции не удалась: раннер вернул код $LASTEXITCODE. Подготовленный сценарий: $preparedFile"
    }
}
finally {
    $env:PLAYWRIGHT_BROWSERS_PATH = $webTestRuntime.PreviousBrowsersPath
}

$artifactFile = Join-Path $outputDirectory "guide.json"
if (-not (Test-Path -LiteralPath $artifactFile -PathType Leaf)) {
    throw "Сценарий отработал, но артефакта инструкции нет. Вызывает ли он saveGuide()?"
}

# Паспорт читается ДО оформления: человеческие разделы — назначение, роли,
# предусловия — из прогона не добываются, и класть их в готовый документ нельзя.
# Документ пересобирается, а паспорт лежит рядом со сценарием, едет в MR и
# переживает пересборку. Дописанное в выходной файл теряется молча на второй.
$passportPath = Join-Path $scenarioRoot "$Scenario.guide.json"
$passport = $null
if (Test-Path -LiteralPath $passportPath -PathType Leaf) {
    try {
        $passport = Get-Content -Raw -LiteralPath $passportPath -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        Write-Warning "Паспорт сценария не разобрался: $passportPath. $($_.Exception.Message)"
    }
}

# Состав обязательных разделов объявляет проект. Объявленный и незаполненный
# раздел — отказ: шаблон с пустыми заголовками хуже отсутствия шаблона, потому
# что документ выглядит оформленным и при этом ничего не сообщает.
$templateFields = @(Get-WorkflowSettingValue -Object $config.userGuides -Name "templateFields" -Default @())
$sections = New-Object System.Collections.ArrayList
$missingFields = New-Object System.Collections.ArrayList
foreach ($field in $templateFields) {
    $fieldName = [string](Get-WorkflowSettingValue -Object $field -Name "name" -Default ([string]$field))
    $fieldTitle = [string](Get-WorkflowSettingValue -Object $field -Name "title" -Default $fieldName)
    if (-not $fieldName) {
        continue
    }
    $value = [string](Get-WorkflowSettingValue -Object $passport -Name $fieldName -Default "")
    if (-not $value.Trim()) {
        [void]$missingFields.Add($fieldName)
        continue
    }
    [void]$sections.Add([pscustomobject]@{ name = $fieldName; title = $fieldTitle; text = $value })
}
if ($missingFields.Count -gt 0) {
    throw ("Паспорт сценария не содержит разделов, объявленных в userGuides.templateFields: " +
        "$($missingFields -join ', '). Заполните их в $passportPath.")
}

# Паспорт вливается в артефакт здесь: рантайм съёмки о нём не знает и знать не
# должен — он ведёт браузер, а не читает манифест проекта.
$artifact = Get-Content -Raw -LiteralPath $artifactFile -Encoding UTF8 | ConvertFrom-Json
Add-Member -InputObject $artifact -NotePropertyName "scenario" -NotePropertyValue $Scenario -Force
Add-Member -InputObject $artifact -NotePropertyName "sections" -NotePropertyValue @($sections) -Force
if ($null -ne $passport) {
    foreach ($name in @("title", "persona", "tasks", "status", "help")) {
        $value = Get-WorkflowSettingValue -Object $passport -Name $name -Default $null
        if ($null -ne $value) {
            # Заголовок из паспорта не перебивает заданный сценарием: сценарий
            # знает, что он снял, а паспорт — к какой задаче это относится.
            if ($name -eq "title" -and [string](Get-WorkflowSettingValue -Object $artifact -Name "title" -Default "")) {
                continue
            }
            Add-Member -InputObject $artifact -NotePropertyName $name -NotePropertyValue $value -Force
        }
    }
}
Write-WorkflowJson -Value $artifact -Path $artifactFile | Out-Null

# Оформление отделено от съёмки: одному проекту нужен самодостаточный HTML,
# другому — страница в корпоративной вики. Пусто — работает встроенный
# оформитель комплекта; договор у обоих один и тот же.
$renderScript = [string](Get-WorkflowSettingValue -Object $config.userGuides -Name "renderScript" -Default "")
$templateSetting = [string](Get-WorkflowSettingValue -Object $config.userGuides -Name "template" -Default "")
$renderPath = if ($renderScript) {
    Resolve-WorkflowPath -RepositoryRoot $repositoryRoot -Path $renderScript
}
else {
    Join-Path $PSScriptRoot "Render-GuideHtml.ps1"
}
if (-not (Test-Path -LiteralPath $renderPath -PathType Leaf)) {
    throw "Оформитель инструкций не найден: $renderPath (userGuides.renderScript)."
}

$renderArguments = @("-GuidePath", $outputDirectory, "-ReportPath", (Join-Path $outputDirectory "render-report.json"))
if ($templateSetting) {
    $templatePath = Resolve-WorkflowPath -RepositoryRoot $repositoryRoot -Path $templateSetting
    if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
        throw "Шаблон инструкции не найден: $templatePath (userGuides.template)."
    }
    $renderArguments += @("-Template", $templatePath)
}

Invoke-WorkflowPowerShell `
    -ScriptPath $renderPath `
    -Arguments $renderArguments `
    -LogPath (Join-Path $runDirectory "$Scenario-render.log") | Out-Null

# Отчёт оформителя — не формальность. Адаптер, который ничего не произвёл и
# промолчал, превращает этап в декорацию: команда считает, что инструкции
# публикуются, а их нет. Поэтому результат проверяется, а не принимается на слово.
$renderReportPath = Join-Path $outputDirectory "render-report.json"
if (-not (Test-Path -LiteralPath $renderReportPath -PathType Leaf)) {
    throw "Оформитель не оставил отчёта: $renderReportPath. Договор описан в docs/1c-development-workflow.md."
}
$renderReport = Get-Content -Raw -LiteralPath $renderReportPath -Encoding UTF8 | ConvertFrom-Json
$producedFiles = @(Get-WorkflowSettingValue -Object $renderReport -Name "files" -Default @())
$publishedUrl = [string](Get-WorkflowSettingValue -Object $renderReport -Name "url" -Default "")
if ($producedFiles.Count -eq 0 -and -not $publishedUrl) {
    throw "Оформитель отработал, но ничего не произвёл: ни файлов, ни адреса публикации ($renderReportPath)."
}

Write-Host ""
foreach ($file in $producedFiles) {
    if (Test-Path -LiteralPath $file -PathType Leaf) {
        Write-Host ("[OK] Инструкция собрана: {0} ({1:N0} байт)" -f $file, (Get-Item -LiteralPath $file).Length)
    }
    else {
        Write-Host "[OK] Оформитель сообщил о файле: $file"
    }
}
if ($publishedUrl) {
    Write-Host "[OK] Опубликовано: $publishedUrl"
}

# Кадры — сырьё оформления. По умолчанию они убираются: в каталоге остаётся
# документ, а не документ плюс десяток картинок, которые уже внутри него.
# Проекту, чей оформитель публикует картинки отдельно, они нужны — тогда
# screenshot.keepFiles.
$shotKeep = [bool](Get-WorkflowSettingValue -Object $shotSettings -Name "keepFiles" -Default $false)
if (-not $shotKeep) {
    Get-ChildItem -LiteralPath $outputDirectory -File -Filter "step-*" -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

# Справка проверяется ЗДЕСЬ, а не отдельной командой. Сценарий только что прошёл
# по тем же формам на живом стенде: если у объекта, о котором инструкция, нет
# страницы F1, это видно ровно сейчас и одним проходом. Отдельный вызов
# выполняется реже всего — а справка и инструкция устаревают вместе.
$helpSettings = Get-WorkflowUserHelpSettings -Config $config

# Паспорт читается здесь же: связь «сценарий — объекты, о которых он» знает
# только он. Паспорта нет — сценарий старый, и требовать по нему нечего.
$declaredHelp = @(Get-WorkflowSettingValue -Object $passport -Name "help" -Default @())

if ($declaredHelp.Count -gt 0) {
    $objects = @(
        $declaredHelp | ForEach-Object {
            # Паспорт называет объект ссылкой «Вид.Имя», как её пишет 1С;
            # проверка ищет по каталогам выгрузки, где вид во множественном числе.
            $parts = ([string]$_).Split(".")
            if ($parts.Count -eq 2) { (Get-WorkflowMetadataDirectory -Kind $parts[0]) + "/" + $parts[1] } else { "" }
        } | Where-Object { $_ }
    )
    $withoutHelp = @(Find-WorkflowObjectsWithoutHelpInComponents `
        -RepositoryRoot $repositoryRoot `
        -Config $config `
        -Objects $objects `
        -Languages $helpSettings.Languages)

    Write-Host ""
    if ($withoutHelp.Count -eq 0) {
        Write-Host "Справка по F1 есть у всех объектов сценария: $($declaredHelp -join ', ')"
    }
    else {
        Write-Host "Объекты сценария без справки по F1: $($withoutHelp -join ', ')"
        Write-Host "Инструкция ведёт по шагам, справка отвечает на вопрос в той форме, где он возник."
        Write-Host "Добавьте её навыком help-add, затем соберите страницы: tools\Update-HelpPages.ps1"
        if ($helpSettings.Enabled) {
            throw "Сценарий описывает объекты без встроенной справки: $($withoutHelp -join ', ')."
        }
    }
}
