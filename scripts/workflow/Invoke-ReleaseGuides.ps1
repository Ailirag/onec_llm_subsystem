<#
.SYNOPSIS
    Цикл пользовательских инструкций по релизу: план по задачам релиза, сборка
    инструкций по готовым сценариям, сводный отчёт.

.DESCRIPTION
    Инструкция по задаче снимается со стенда, на котором стоит РЕЛИЗ, и по каждой
    задаче релиза отдельно. Этап Build-UserGuide умеет один сценарий; этот скрипт
    проводит через него весь релиз и показывает, где инструкции нет и почему.

    Запуск ручной, в фазы задачи не входит — по тем же причинам, что и сам этап
    инструкций: он работает с данными стенда и с внешними сервисами конфигурации.

    Шаги (каждый можно начать заново ключом -From):

      plan    — состав релиза от адаптера releaseGuides.sourceScript (или готовый
                файл -Manifest), класс каждой задачи по изменённым путям и
                сценарии, которые к ней относятся (паспорта *.guide.json);
      guides  — по каждому сценарию: данные (releaseGuides.seedScript по списку
                seeds паспорта), затем Build-UserGuide на публикации персоны;
      report  — index.html и report.json в каталоге релиза.

    План пересчитывается при каждом запуске — по составу, сохранённому шагом
    plan, и текущим паспортам: сценарий, дописанный после plan, попадает в
    сборку без повторного обращения к источнику состава.

    Ключ -ProbeSeeds вместо сборки прогоняет сиды выбранных сценариев с откатом
    (seedScript с -Mode rollback): так проверяется черновик сида, который написал
    агент, — не записав его данных в базу стенда.

    Перед сидами на стенде выполняется базовая подготовка (standBaseline, см.
    Invoke-WorkflowStandBaseline), в том числе и перед пробой, а после сидов
    каждого сценария регламентные задания выключаются снова.

    Стенд этот шаг не поднимает: берётся опубликованный стенд (как у
    Build-UserGuide) или адреса, переданные явно. Явные адреса проверяются до
    первого сценария: недоступная публикация — одна понятная причина вместо
    отказа каждого сценария по отдельности.

.PARAMETER Release
    Имя релиза, например версия в трекере задач.

.PARAMETER Manifest
    Готовый манифест релиза вместо вызова адаптера. Для ручного состава и для
    проектов, где адаптера ещё нет.

.PARAMETER Task
    Ключи задач через запятую: собрать инструкции только по ним. План всегда
    строится по всему релизу, чтобы отчёт оставался полным.

.PARAMETER From
    С какого шага начать: plan (по умолчанию), guides, report.

.PARAMETER Url
    Адрес публикации для сценариев без персоны. Пусто — стенд Web UI ветки.

.PARAMETER PersonaUrl
    Публикации персон: "Имя=URL;Имя2=URL". Сценарий с персоной без публикации
    не собирается: снимок под другим пользователем покажет чужие права.

.PARAMETER BasePath
    Каталог базы стенда — нужен, если паспорта требуют данные (seeds).

.PARAMETER ProbeSeeds
    Только проба сидов выбранных сценариев с откатом: инструкции не собираются,
    результаты сборки не меняются. Адаптер seedScript должен принимать
    -Mode rollback.

.EXAMPLE
    scripts\workflow\Invoke-ReleaseGuides.ps1 -Release "1С:УТ_02.10.2026" -Url http://localhost:8091/ut
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Release,

    [string]$Manifest = "",

    # Строкой через запятую: при запуске через -File массив не разбирается.
    [string]$Task = "",

    [ValidateSet("plan", "guides", "report")]
    [string]$From = "plan",

    [string]$Url = "",
    [string]$PersonaUrl = "",
    [string]$BasePath = "",
    [int]$Port = 0,
    [string]$AppName = "",
    [switch]$ProbeSeeds
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Workflow.Common.ps1")
. (Join-Path $PSScriptRoot "Workflow.ReleaseGuides.ps1")

$repositoryRoot = Get-WorkflowRepositoryRoot -StartPath $PSScriptRoot
$config = Get-WorkflowConfig -RepositoryRoot $repositoryRoot

# Раздела может не быть: проект поставлен версией комплекта, где цикла ещё не
# было. Это «не установлено», а не «выключено», и лечится подъёмом комплекта.
if ($null -eq $config.PSObject.Properties["releaseGuides"]) {
    throw "В .1c-workflow.json нет раздела releaseGuides. Поднимите комплект фазой KitUpdate."
}
if (-not [bool]$config.releaseGuides.enabled) {
    throw "Цикл инструкций по релизу выключен: releaseGuides.enabled в .1c-workflow.json."
}
if ($null -eq $config.PSObject.Properties["userGuides"] -or -not [bool]$config.userGuides.enabled) {
    throw "Цикл собирает инструкции этапом Build-UserGuide, а он выключен: userGuides.enabled в .1c-workflow.json."
}

$releaseSettings = $config.releaseGuides
$outputRoot = Resolve-WorkflowPath -RepositoryRoot $repositoryRoot `
    -Path ([string](Get-WorkflowSettingValue -Object $releaseSettings -Name "outputDir" -Default ".build/releases"))
$releaseRoot = Join-Path $outputRoot (ConvertTo-WorkflowReleaseSlug -Release $Release)
[System.IO.Directory]::CreateDirectory($releaseRoot) | Out-Null
$manifestPath = Join-Path $releaseRoot "manifest.json"
$planPath = Join-Path $releaseRoot "plan.json"
$resultsPath = Join-Path $releaseRoot "results.json"
$logRoot = Join-Path $releaseRoot "logs"
$guideRoot = Join-Path $releaseRoot "guides"

$scenarioRoot = Resolve-WorkflowPath -RepositoryRoot $repositoryRoot -Path ([string]$config.userGuides.scenarios)
$passportScan = Get-WorkflowGuidePassports -ScenarioRoot $scenarioRoot
$passportByScenario = @{}
foreach ($passport in @($passportScan.Passports)) {
    $passportByScenario[$passport.Scenario] = $passport
}

Write-Host "Релиз:   $Release"
Write-Host "Каталог: $releaseRoot"
Write-Host ""

# ── plan ──────────────────────────────────────────────────────────────────────
if ($From -eq "plan") {
    if ($Manifest) {
        $sourceManifest = [System.IO.Path]::GetFullPath($Manifest)
        if ($sourceManifest -ne [System.IO.Path]::GetFullPath($manifestPath)) {
            Copy-Item -LiteralPath $sourceManifest -Destination $manifestPath -Force
        }
    }
    else {
        $sourceScriptSetting = [string](Get-WorkflowSettingValue -Object $releaseSettings -Name "sourceScript" -Default "")
        if (-not $sourceScriptSetting) {
            throw ("Состав релиза брать неоткуда: releaseGuides.sourceScript не задан. " +
                "Передайте готовый манифест ключом -Manifest.")
        }
        $sourceScript = Resolve-WorkflowPath -RepositoryRoot $repositoryRoot -Path $sourceScriptSetting
        if (-not (Test-Path -LiteralPath $sourceScript -PathType Leaf)) {
            throw "Адаптер состава релиза не найден: $sourceScript"
        }
        Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
        Invoke-WorkflowPowerShell `
            -ScriptPath $sourceScript `
            -Arguments @("-Release", $Release, "-OutputPath", $manifestPath) `
            -LogPath (Join-Path $logRoot "source.log") | Out-Null
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            throw "Адаптер состава релиза отработал, но манифеста нет: $manifestPath"
        }
    }
}

if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    # План пересчитывается и после plan: паспорта могли появиться позже состава.
    $plan = Update-WorkflowReleasePlan -ManifestPath $manifestPath -Release $Release `
        -Passports @($passportScan.Passports) -PlanPath $planPath

    Write-Host "План:"
    foreach ($item in @($plan.Tasks)) {
        $scenarios = if (@($item.Scenarios).Count -gt 0) { " → " + (@($item.Scenarios) -join ", ") } else { "" }
        Write-Host ("  {0,-12} {1,-10} {2,-11}{3}" -f $item.Key, $item.Class, $item.Coverage, $scenarios)
    }
    foreach ($problem in @($passportScan.Problems)) {
        Write-Host "  [паспорт] $problem"
    }
    Write-Host ""
}

if (-not (Test-Path -LiteralPath $planPath -PathType Leaf)) {
    throw "Плана релиза нет: $planPath. Начните с шага plan."
}
$plan = Get-Content -Raw -LiteralPath $planPath -Encoding UTF8 | ConvertFrom-Json

$results = @{}
if (Test-Path -LiteralPath $resultsPath -PathType Leaf) {
    $stored = Get-Content -Raw -LiteralPath $resultsPath -Encoding UTF8 | ConvertFrom-Json
    foreach ($property in @($stored.PSObject.Properties)) {
        $results[$property.Name] = $property.Value
    }
}

# ── guides ────────────────────────────────────────────────────────────────────
if ($From -ne "report") {
    $selectedTasks = @($plan.Tasks)
    if ($Task) {
        $wanted = @($Task -split ',' | ForEach-Object { $_.Trim().ToUpperInvariant() } | Where-Object { $_ })
        $known = @($plan.Tasks | ForEach-Object { ([string]$_.Key).ToUpperInvariant() })
        $missing = @($wanted | Where-Object { $known -notcontains $_ })
        if ($missing.Count -gt 0) {
            # Молча собрать ничего по опечатке в ключе — худший исход: прогон
            # «успешен», а инструкции нет.
            throw "Задач нет в релизе: $($missing -join ', ')."
        }
        $selectedTasks = @($plan.Tasks | Where-Object { $wanted -contains ([string]$_.Key).ToUpperInvariant() })
    }

    $personaUrls = ConvertFrom-WorkflowPersonaUrls -Value $PersonaUrl
    $guideScript = Resolve-WorkflowPath -RepositoryRoot $repositoryRoot `
        -Path ([string](Get-WorkflowSettingValue -Object $config.userGuides -Name "script" -Default "tools/Build-UserGuide.ps1"))
    $seedScriptSetting = [string](Get-WorkflowSettingValue -Object $releaseSettings -Name "seedScript" -Default "")

    $scenarioNames = @($selectedTasks | ForEach-Object { @($_.Scenarios) } | Sort-Object -Unique)
    if ($scenarioNames.Count -eq 0) {
        Write-Host "Сценариев для сборки нет."
    }

    # Явные адреса выбранных сценариев проверяются до первого сценария.
    $addresses = New-Object System.Collections.ArrayList
    if ($Url) {
        [void]$addresses.Add($Url)
    }
    if (-not $ProbeSeeds) {
        foreach ($scenario in $scenarioNames) {
            $passport = $passportByScenario[$scenario]
            if ($null -ne $passport -and $passport.Persona -and $personaUrls.ContainsKey($passport.Persona) -and
                -not $addresses.Contains($personaUrls[$passport.Persona])) {
                [void]$addresses.Add($personaUrls[$passport.Persona])
            }
        }
    }
    if ($scenarioNames.Count -gt 0) {
        $unreachable = @(foreach ($address in $addresses) {
            $reason = Test-WorkflowGuidePublication -Url $address
            if ($reason) { $reason }
        })
        if ($unreachable.Count -gt 0) {
            throw ("Стенд не отвечает, сценарии не запускались:`n  " + ($unreachable -join "`n  ") + "`n" +
                "Поднимите публикацию (Apache стенда сам не стартует после перезагрузки машины) и повторите с -From guides.")
        }
    }

    # Базовая подготовка стенда (standBaseline) — до первого сида и до первой
    # пробы: проба с откатом, первой тронувшая предопределённые данные, оставила
    # бы в кэше веб-сервера ссылки на откатанные элементы.
    if ($scenarioNames.Count -gt 0) {
        foreach ($line in @(Invoke-WorkflowStandBaseline -RepositoryRoot $repositoryRoot -Config $config `
                -Url $Url -LogPath (Join-Path $logRoot "stand-baseline.log"))) {
            Write-Host "Стенд: $line"
        }
        Write-Host ""
    }

    # ── проба сидов ───────────────────────────────────────────────────────────
    if ($ProbeSeeds) {
        if (-not $seedScriptSetting -or -not $BasePath) {
            throw "Пробе сидов нужны releaseGuides.seedScript и -BasePath."
        }
        $probeFailed = 0
        foreach ($scenario in $scenarioNames) {
            $passport = $passportByScenario[$scenario]
            if ($null -eq $passport -or @($passport.Seeds).Count -eq 0) {
                Write-Host "== $scenario — сидов нет"
                continue
            }
            Write-Host "== $scenario — проба сидов: $(@($passport.Seeds) -join ', ')"
            $probe = Invoke-WorkflowPowerShell `
                -ScriptPath (Resolve-WorkflowPath -RepositoryRoot $repositoryRoot -Path $seedScriptSetting) `
                -Arguments @("-BasePath", $BasePath, "-Seed", (@($passport.Seeds) -join ","), "-Mode", "rollback") `
                -LogPath (Join-Path $logRoot "$scenario-seed-probe.log") `
                -AllowFailure
            if ($probe.ExitCode -eq 0) {
                Write-Host "   проходят (с откатом)"
            }
            else {
                $probeFailed += 1
                Write-Host "   не проходят, лог: $($probe.LogPath)"
            }
        }
        Write-Host ""
        Write-Host "Проба сидов: сценариев $($scenarioNames.Count), с ошибкой $probeFailed. Сиды откачены, инструкции не собирались; на стенде осталась только базовая подготовка."
        if ($probeFailed -gt 0) {
            exit 1
        }
        exit 0
    }

    foreach ($scenario in $scenarioNames) {
        $passport = $passportByScenario[$scenario]
        $at = (Get-Date).ToString("dd.MM.yyyy HH:mm")
        Write-Host "== $scenario"

        if ($null -eq $passport) {
            # Паспорт был при планировании, а теперь исчез или испорчен.
            $results[$scenario] = [pscustomobject]@{ Status = "failed"; Detail = "паспорт сценария не найден или с ошибкой"; Guide = ""; Log = ""; At = $at }
            Write-Host "   паспорт не найден"
            continue
        }

        $targetUrl = $Url
        if ($passport.Persona) {
            if (-not $personaUrls.ContainsKey($passport.Persona)) {
                $results[$scenario] = [pscustomobject]@{ Status = "failed"; Detail = "нет публикации персоны $($passport.Persona) (-PersonaUrl)"; Guide = ""; Log = ""; At = $at }
                Write-Host "   нет публикации персоны $($passport.Persona)"
                continue
            }
            $targetUrl = $personaUrls[$passport.Persona]
        }

        if (@($passport.Seeds).Count -gt 0) {
            if (-not $seedScriptSetting -or -not $BasePath) {
                $results[$scenario] = [pscustomobject]@{ Status = "failed"; Detail = "сценарию нужны данные ($(@($passport.Seeds) -join ', ')), а releaseGuides.seedScript или -BasePath не заданы"; Guide = ""; Log = ""; At = $at }
                Write-Host "   данные не залиты: нет seedScript или -BasePath"
                continue
            }
            $seedRun = Invoke-WorkflowPowerShell `
                -ScriptPath (Resolve-WorkflowPath -RepositoryRoot $repositoryRoot -Path $seedScriptSetting) `
                -Arguments @("-BasePath", $BasePath, "-Seed", (@($passport.Seeds) -join ",")) `
                -LogPath (Join-Path $logRoot "$scenario-seed.log") `
                -AllowFailure
            if ($seedRun.ExitCode -ne 0) {
                $results[$scenario] = [pscustomobject]@{ Status = "failed"; Detail = "данные не залиты (код $($seedRun.ExitCode))"; Guide = ""; Log = $seedRun.LogPath; At = $at }
                Write-Host "   данные не залиты, лог: $($seedRun.LogPath)"
                continue
            }
            # Сид мог включить функциональные опции, а с ними и зависящие от них
            # регламентные задания: они выключаются снова, до сеанса сценария.
            foreach ($line in @(Invoke-WorkflowStandBaseline -RepositoryRoot $repositoryRoot -Config $config `
                    -Url $Url -LogPath (Join-Path $logRoot "$scenario-stand-jobs.log") -ScheduledJobsOnly)) {
                Write-Host "   стенд: $line"
            }
        }

        $arguments = @("-Scenario", $scenario, "-OutputRoot", $guideRoot)
        if ($targetUrl) {
            $arguments += @("-Url", $targetUrl)
        }
        else {
            if ($Port -gt 0) { $arguments += @("-Port", [string]$Port) }
            if ($AppName) { $arguments += @("-AppName", $AppName) }
        }
        $run = Invoke-WorkflowPowerShell `
            -ScriptPath $guideScript `
            -Arguments $arguments `
            -LogPath (Join-Path $logRoot "$scenario-guide.log") `
            -AllowFailure
        # Что именно получилось, знает оформитель: у встроенного это index.html,
        # у адаптера проекта — свой формат или вовсе страница в вики. Поэтому
        # результат берётся из его отчёта, а имя файла угадывается только как
        # запасной вариант для инструкций, собранных прежними версиями.
        $scenarioDirectory = Join-Path $guideRoot $scenario
        $renderReportPath = Join-Path $scenarioDirectory "render-report.json"
        $guideLink = ""
        if (Test-Path -LiteralPath $renderReportPath -PathType Leaf) {
            try {
                $renderReport = Get-Content -Raw -LiteralPath $renderReportPath -Encoding UTF8 | ConvertFrom-Json
                $publishedUrl = [string](Get-WorkflowSettingValue -Object $renderReport -Name "url" -Default "")
                $producedFiles = @(Get-WorkflowSettingValue -Object $renderReport -Name "files" -Default @())
                if ($publishedUrl) {
                    $guideLink = $publishedUrl
                }
                elseif ($producedFiles.Count -gt 0) {
                    $guideLink = "guides/$scenario/" + (Split-Path ([string]@($producedFiles)[0]) -Leaf)
                }
            }
            catch {
                Write-Warning "Отчёт оформителя не разобрался: $renderReportPath. $($_.Exception.Message)"
            }
        }
        if (-not $guideLink -and (Test-Path -LiteralPath (Join-Path $scenarioDirectory "index.html") -PathType Leaf)) {
            $guideLink = "guides/$scenario/index.html"
        }
        if ($run.ExitCode -eq 0 -and $guideLink) {
            $results[$scenario] = [pscustomobject]@{ Status = "built"; Detail = ""; Guide = $guideLink; Log = $run.LogPath; At = $at }
            Write-Host "   собрана"
        }
        else {
            $reason = @($run.Output | Where-Object { $_ -match '\S' } | Select-Object -Last 1) -join ""
            $results[$scenario] = [pscustomobject]@{ Status = "failed"; Detail = "сборка не удалась: $reason"; Guide = ""; Log = $run.LogPath; At = $at }
            Write-Host "   не собрана, лог: $($run.LogPath)"
        }
        # Результат пишется после каждого сценария: прерванный цикл не теряет
        # уже собранного, а следующий запуск с -Task дописывает, а не затирает.
        Write-WorkflowJson -Value ([pscustomobject]$results) -Path $resultsPath | Out-Null
    }
    Write-WorkflowJson -Value ([pscustomobject]$results) -Path $resultsPath | Out-Null
    Write-Host ""
}

# ── report ────────────────────────────────────────────────────────────────────
$html = ConvertTo-WorkflowReleaseReportHtml `
    -Plan $plan `
    -Results $results `
    -Passports $passportByScenario `
    -Problems @($passportScan.Problems)
$reportPath = Join-Path $releaseRoot "index.html"
[System.IO.File]::WriteAllText($reportPath, $html, [System.Text.UTF8Encoding]::new($false))
$releaseReportPath = Join-Path $releaseRoot "report.json"
Write-WorkflowJson -Value ([pscustomobject]@{
    release = $plan.Release
    generatedAt = (Get-Date).ToString("o")
    tasks = @($plan.Tasks)
    results = [pscustomobject]$results
    passportProblems = @($passportScan.Problems)
    guides = @(
        $results.Keys | Sort-Object | ForEach-Object {
            [pscustomobject]@{
                scenario = $_
                guide = [string]$results[$_].Guide
                status = [string]$results[$_].Status
            }
        }
    )
}) -Path $releaseReportPath | Out-Null

# Сводка по релизу — такой же документ, как инструкция, и проект, у которого
# инструкции уезжают в корпоративную вики, ждёт там же и сводку. Иначе
# универсальность получится половинчатой: сценарии оформлены по-своему, а список
# по релизу всё равно нашей HTML-страницей. Встроенный оформитель зовётся только
# при своём адаптере — собственную страницу выше он бы просто переписал тем же.
$releaseRenderScript = [string](Get-WorkflowSettingValue -Object $config.userGuides -Name "renderScript" -Default "")
if ($releaseRenderScript) {
    $releaseRenderPath = Resolve-WorkflowPath -RepositoryRoot $repositoryRoot -Path $releaseRenderScript
    if (-not (Test-Path -LiteralPath $releaseRenderPath -PathType Leaf)) {
        throw "Оформитель инструкций не найден: $releaseRenderPath (userGuides.renderScript)."
    }
    $releaseRenderArguments = @(
        "-IndexPath", $releaseReportPath,
        "-ReportPath", (Join-Path $releaseRoot "render-report.json")
    )
    $releaseTemplate = [string](Get-WorkflowSettingValue -Object $config.userGuides -Name "template" -Default "")
    if ($releaseTemplate) {
        $releaseRenderArguments += @(
            "-Template", (Resolve-WorkflowPath -RepositoryRoot $repositoryRoot -Path $releaseTemplate))
    }
    Invoke-WorkflowPowerShell `
        -ScriptPath $releaseRenderPath `
        -Arguments $releaseRenderArguments `
        -LogPath (Join-Path $logRoot "release-render.log") | Out-Null
}

$failed = @($results.Keys | Where-Object { [string]$results[$_].Status -eq "failed" })
$needed = @($plan.Tasks | Where-Object { $_.Coverage -eq "needed" })
Write-Host "[OK] Отчёт: $reportPath"
Write-Host ("     собрано: {0}, с ошибкой: {1}, задач без сценария: {2}" -f
    @($results.Keys | Where-Object { [string]$results[$_].Status -eq "built" }).Count, $failed.Count, $needed.Count)
if ($failed.Count -gt 0) {
    exit 1
}
