[CmdletBinding()]
param(
    [string]$V8Path = "",
    [string]$ReportPath = "",
    [switch]$CompileOnly,
    [switch]$RequireClean,
    [switch]$SkipFunctionalTests,
    [switch]$IncludeHttp,
    [switch]$IncludeWebUi,
    [switch]$KeepTemporaryFiles,

    # Выпуск собирает базу заново, не трогая кэш. Кэш — это доверие к записи,
    # сделанной прошлым прогоном; для артефакта, который уедет в эксплуатацию,
    # такого доверия мало. Экономия здесь не нужна: выпуск делается редко, а
    # платит за него тот, кто ставит сборку.
    [switch]$NoBuiltBaseCache,

    # Не выгружать CF. Артефакт нужен только выпуску: Build-Release.ps1 выполняет
    # preflight сам и читает из его отчёта путь к CF. На задачных фазах выгрузка
    # делалась и тут же удалялась вместе с временным деревом — на большой
    # конфигурации это минуты за фазу, отданные ни за что.
    [switch]$SkipCfDump,

    # Готовые отчёты тех же проверок, выполненных вызывающим (фазой Verify — через
    # gate). Файл существует — шаг не выполняется повторно, а отмечается как
    # переиспользованный. Отсутствует — проверка выполняется как обычно, поэтому
    # ошибиться путём означает потерять скорость, а не проверку.
    [string]$SourceIntegrityReport = "",
    [string]$TestMaintenanceReport = "",

    # Объём Web UI регрессии. Пусто означает full: вызов без указания объёма
    # получает полный прогон, чтобы прежние вызовы не начали молча проверять меньше.
    #   full           — весь сьют;
    #   smoke          — только файлы с тегом smoke;
    #   affected       — только затронутое политикой, без обязательного минимума;
    #   affected+smoke — smoke плюс каталоги, затронутые правками по политике.
    [ValidateSet("", "full", "smoke", "affected", "affected+smoke")]
    [string]$WebUiScope = "",

    # База сравнения для отбора затронутого. Пусто — берётся из политики.
    [string]$WebUiBaseRef = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Workflow.Common.ps1")

function Get-WebUiRunPlan {
    <#
    .SYNOPSIS
    Делит обязательный объём Web UI на два прогона: сначала затронутое правкой,
    потом обязательный минимум.

    .DESCRIPTION
    Порядок здесь — не косметика. Прогон, доказывающий разрабатываемую
    функциональность, обязан идти ПЕРВЫМ: если он падает, дальше проверять нечего.
    Раньше объём собирался объединением, smoke попадал в список первым, и тест
    задачи выполнялся последним — то есть самый вероятный и самый дешёвый отказ
    приходил позже всех, уже оплатив полный дым.

    Возвращает объект с полями:
      FullRun  — прогон один и целиком (объём `full` либо правило требует весь сьют);
      Affected — цели, доказывающие правку; идут до функционального дыма;
      Smoke    — обязательный минимум за вычетом уже покрытого шагом Affected.

    Вычитание обязательно. Без него файл, попавший и в smoke, и в затронутый
    каталог, прогонялся бы дважды: второй раз — уже по данным, изменённым первым
    прогоном, и неидемпотентный тест падал бы на ровном месте. С вычитанием
    объединение двух шагов совпадает с прежним единственным списком, то есть
    обязательный объём не уменьшается.

    Печатает выбранное вслух намеренно: объём прогона обязан быть видимым в логе
    фазы, иначе «прошло» перестаёт отличаться от «прошло то, что выбрали».
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [string]$Scope,

        [string]$BaseRef = "",

        [string]$PolicyReportPath = "",

        [bool]$PolicyReportReady = $false,

        # Коммит и отпечаток текущего дерева. Пустые — переиспользование не
        # рассматривается вовсе: зачесть чужой прогон, не зная, чему он
        # принадлежит, нельзя.
        [string]$Commit = "",

        [string]$Fingerprint = ""
    )

    $suiteRelative = ([string]$Config.webUiTests.suite).Replace('\', '/').Trim('/')
    # Полный прогон — это ветви сьюта поимённо, а не его корень. Корень движок
    # обошёл бы рекурсивно и затянул `pending`: отложенные сценарии красные по
    # определению, и на выпуске это выглядело бы как сломанный регресс.
    $fullRunTargets = @(
        Get-WorkflowSuiteRootTargets -RepositoryRoot $RepositoryRoot -SuiteRelativePath $suiteRelative
    )

    if ($Scope -eq "full") {
        # Полный объём — единственный, где есть что вычитать: остальные и так
        # меньше сьюта, и экономить на них нечего.
        #
        # Вычитается ДОКАЗАННОЕ НА ЭТОМ ЖЕ ДЕРЕВЕ: тот же коммит и тот же
        # отпечаток файлов. Объединение зачтённого и прогоняемого равно полному
        # списку — это проверяет Select-WorkflowWebUiReuse, и без такого равенства
        # переиспользование не включается. Иначе `full` в отчёте означал бы
        # меньше, чем написано.
        $proven = Get-WorkflowProvenWebUiFiles `
            -RepositoryRoot $RepositoryRoot `
            -Config $Config `
            -Commit $Commit `
            -Fingerprint $Fingerprint
        $allFiles = @(Get-WorkflowSuiteFiles -RepositoryRoot $RepositoryRoot -SuiteRelativePath $suiteRelative)
        $reuse = Select-WorkflowWebUiReuse -AllFiles $allFiles -ProvenFiles $proven.Files

        if (-not $reuse.Reuse) {
            Write-Host "Web UI объём: full — весь сьют одним прогоном ($($reuse.Reason))."
            return [pscustomobject]@{
                FullRun = $true
                Targets = $fullRunTargets
                Affected = @()
                Smoke = @()
                Reused = @()
                ReusedFrom = @()
            }
        }

        Write-Host "Web UI объём: full, из них зачтено прошлыми прогонами на этом же дереве: $(@($reuse.Reused).Count) из $($allFiles.Count)."
        foreach ($source in @($proven.Reports)) {
            Write-Host "  зачтено по отчёту: $source"
        }
        if (@($reuse.Remainder).Count -eq 0) {
            Write-Host "  прогонять нечего: весь сьют уже доказан на этом дереве."
        }
        else {
            Write-Host "  осталось прогнать: $(@($reuse.Remainder).Count)"
        }
        return [pscustomobject]@{
            FullRun = $true
            Targets = @($reuse.Remainder | ForEach-Object { "$suiteRelative/$_" })
            Affected = @()
            Smoke = @()
            Reused = @($reuse.Reused)
            ReusedFrom = @($proven.Reports)
        }
    }

    # Обязательный минимум нужен только объёмам, которые его включают. У `affected`
    # его нет: там прогоняется ровно связанное с правкой.
    $smokeFiles = @()
    if ($Scope -ne "affected") {
        $smokeFiles = @(
            Get-WorkflowSuiteFilesByTag `
                -RepositoryRoot $RepositoryRoot `
                -SuiteRelativePath $suiteRelative `
                -Tag "smoke"
        )
        if ($smokeFiles.Count -eq 0) {
            throw "Web UI scope '$Scope' requires at least one test tagged 'smoke' in $suiteRelative. Tag the minimal set explicitly instead of falling back to a silent full run."
        }
    }

    $affected = New-Object System.Collections.ArrayList
    if ($Scope -eq "affected" -or $Scope -eq "affected+smoke") {
        $selection = Get-WorkflowAffectedSuiteTargets `
            -RepositoryRoot $RepositoryRoot `
            -Config $Config `
            -BaseRef $BaseRef `
            -ReportPath $PolicyReportPath `
            -ReuseExistingReport:$PolicyReportReady

        if ($selection.WholeSuite) {
            Write-Host "Web UI объём: правило политики требует сьют ЦЕЛИКОМ ($(@($selection.WholeSuiteRules) -join ', ')) — прогон полный."
            Write-Host "  Это не защита, а следствие слишком широкого правила: чем точнее карта, тем короче обязательный объём."
            Write-Host "  Делить такой прогон на «затронутое» и «минимум» нечего: затронутое и есть весь сьют."
            return [pscustomobject]@{
                FullRun = $true
                Targets = $fullRunTargets
                Affected = @()
                Smoke = @()
                Reused = @()
                ReusedFrom = @()
            }
        }
        foreach ($target in @($selection.Targets)) {
            if (-not $affected.Contains($target)) {
                [void]$affected.Add($target)
            }
        }
    }

    $smoke = New-Object System.Collections.ArrayList
    foreach ($file in $smokeFiles) {
        $covered = $false
        foreach ($target in $affected) {
            # Цель отбора — каталог сьюта без завершающего слэша (его снимает
            # ConvertFrom-WorkflowTestPathPattern), поэтому сравнение идёт и на
            # равенство, и на префикс с явным разделителем. Без разделителя
            # каталог `03-reports` покрыл бы `03-reports-old`.
            if ($file -eq $target -or
                $file.StartsWith("$target/", [System.StringComparison]::OrdinalIgnoreCase)) {
                $covered = $true
                break
            }
        }
        if (-not $covered) {
            [void]$smoke.Add($file)
        }
    }

    if ($Scope -eq "affected") {
        if ($affected.Count -eq 0) {
            Write-Host "Web UI объём: affected — политика не связала правку ни с одним сценарием сьюта."
            Write-Host "  Это не пропуск проверки: для прикладной логики и HTTP-контракта политика требует"
            Write-Host "  функциональные тесты, и они прогоняются целиком, без ограничения объёма."
        }
        else {
            Write-Host "Web UI объём: affected — целей $($affected.Count), обязательный минимум не добавляется:"
            foreach ($target in $affected) {
                Write-Host "       $target"
            }
        }
        return [pscustomobject]@{
            FullRun = $false
            Targets = @()
            Affected = @($affected)
            Smoke = @()
            Reused = @()
            ReusedFrom = @()
        }
    }

    Write-Host "Web UI объём: $Scope — два прогона в порядке «сначала правка, потом минимум»."
    if ($affected.Count -gt 0) {
        Write-Host "  1) затронутое правкой, целей $($affected.Count) — идёт ДО функционального дыма:"
        foreach ($target in $affected) {
            Write-Host "       $target"
        }
    }
    else {
        Write-Host "  1) затронутого по политике нет — первый прогон не выполняется."
    }
    if ($smoke.Count -gt 0) {
        Write-Host "  2) обязательный минимум smoke, целей $($smoke.Count):"
        foreach ($target in $smoke) {
            Write-Host "       $target"
        }
    }
    else {
        Write-Host "  2) обязательный минимум smoke целиком вошёл в первый прогон — повторно не гоняется."
    }

    return [pscustomobject]@{
        FullRun = $false
        Targets = @()
        Affected = @($affected)
        Smoke = @($smoke)
        Reused = @()
        ReusedFrom = @()
    }
}

function Invoke-WebUiStage {
    <#
    .SYNOPSIS
    Один прогон Web UI внутри preflight: свой шаг, свой отчёт, свои артефакты.

    .DESCRIPTION
    Прогонов в фазе может быть два — затронутое до функционального дыма и
    обязательный минимум после него. Сборка аргументов вынесена сюда потому, что
    две её копии разошлись бы, и один из прогонов однажды пошёл бы на других
    таймаутах или на другом стенде.

    ПУСТОЙ список целей означает ВЕСЬ СЬЮТ: так его понимает раннер. Вызывать с
    пустым списком, имея в виду «запускать нечего», нельзя — получится полный
    прогон вместо пропуска.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.ArrayList]$Steps,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [Parameter(Mandatory = $true)]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [string]$BasePath,

        [Parameter(Mandatory = $true)]
        [string]$V8Executable,

        [Parameter(Mandatory = $true)]
        [string]$StandBranch,

        [Parameter(Mandatory = $true)]
        [string]$ReportPath,

        [Parameter(Mandatory = $true)]
        [string]$ArtifactsPath,

        [Parameter(Mandatory = $true)]
        [string]$LogPath,

        [AllowEmptyCollection()]
        [string[]]$Targets = @(),

        # Оставить Apache поднятым: за этим прогоном последует ещё один.
        [switch]$KeepApache,

        # Подключиться к стенду, оставленному предыдущим прогоном.
        [switch]$ReuseApache
    )

    # Список аргументов собирается ДО вызова и в скобках. Запись
    # `-Arguments @(...) + $extra` не работает: в позиции аргумента PowerShell
    # разбирает `+` как отдельный позиционный параметр и падает с «A positional
    # parameter cannot be found that accepts argument '+'».
    $arguments = @(
        "-BasePath", $BasePath,
        "-V8Path", $V8Executable,
        "-Port", ([string](Get-WorkflowStandPort `
            -Config $Config `
            -BranchName $StandBranch `
            -Kind "web-ui" `
            -FallbackPort ([int]$Config.webUiTests.defaultPort))),
        "-AppName", (Get-WorkflowStandAppName `
            -Config $Config `
            -BranchName $StandBranch `
            -DefaultAppName ([string]$Config.webUiTests.defaultAppName)),
        "-CommandTimeoutSeconds", ([string]$Config.webUiTests.commandTimeoutSeconds),
        "-GlobalTimeoutSeconds", ([string]$Config.webUiTests.globalTimeoutSeconds),
        "-ReportPath", $ReportPath,
        "-ArtifactsPath", $ArtifactsPath,
        "-SkipStandInitialization"
    )
    # Цели передаются ОДНИМ параметром через запятую. Повторение
    # `-TestPath a -TestPath b` PowerShell отклоняет: «parameter 'TestPath' is
    # specified more than once». Запятая в пути сьюта сломала бы разбор, но такие
    # имена и без того недопустимы в путях тестов.
    if (@($Targets).Count -gt 0) {
        $arguments += @("-TestPath", (@($Targets) -join ','))
    }
    if ($KeepApache) {
        $arguments += "-KeepApache"
    }
    if ($ReuseApache) {
        $arguments += "-ReuseApache"
    }

    Invoke-PreflightStep -Steps $Steps -Name $Name -LogPath $LogPath -Action {
        Invoke-WorkflowPowerShell `
            -ScriptPath $ScriptPath `
            -Arguments $arguments `
            -LogPath $LogPath
    }
}

function Invoke-PreflightStep {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.ArrayList]$Steps,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,

        [string]$LogPath = ""
    )

    $startedAt = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        & $Action | Out-Null
        [void]$Steps.Add(
            (New-WorkflowStepResult `
                -Name $Name `
                -Success $true `
                -LogPath $LogPath `
                -DurationSeconds $startedAt.Elapsed.TotalSeconds)
        )
    }
    catch {
        [void]$Steps.Add(
            (New-WorkflowStepResult `
                -Name $Name `
                -Success $false `
                -ExitCode 1 `
                -LogPath $LogPath `
                -Message $_.Exception.Message `
                -DurationSeconds $startedAt.Elapsed.TotalSeconds)
        )
        throw
    }
}

function Invoke-WithPreservedLocalRegistry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Action
    )

    $registryPath = Join-Path $RepositoryRoot ".v8-project.json"
    $registryExisted = Test-Path -LiteralPath $registryPath -PathType Leaf
    [byte[]]$registryBytes = if ($registryExisted) {
        [System.IO.File]::ReadAllBytes($registryPath)
    }
    else {
        @()
    }

    try {
        & $Action
    }
    finally {
        if ($registryExisted) {
            [System.IO.File]::WriteAllBytes($registryPath, $registryBytes)
        }
        elseif (Test-Path -LiteralPath $registryPath -PathType Leaf) {
            Remove-Item -LiteralPath $registryPath -Force
        }
    }
}

function Test-WorkflowConfigFlag {
    param(
        [object]$Object,
        [string]$Name
    )

    if ($null -eq $Object) {
        return $false
    }
    $property = $Object.PSObject.Properties[$Name]
    return $null -ne $property -and [bool]$property.Value
}

$repositoryRoot = Get-WorkflowRepositoryRoot -StartPath $PSScriptRoot
$config = Get-WorkflowConfig -RepositoryRoot $repositoryRoot

# Выключенный набор проверок называется ВСЛУХ. Прежде он просто не запускался, и
# отличить «проверки прошли» от «проверок не было» по выводу фазы было нельзя:
# зелёный прогон выглядел одинаково в обоих случаях. Один сброс настроек
# установщиком — и фаза месяцами подтверждала бы пустоту.
$disabledSuites = @()
foreach ($suite in @(
    @{ Name = "функциональные проверки"; Key = "functionalTests" },
    @{ Name = "Web UI регрессия"; Key = "webUiTests" },
    @{ Name = "модульные тесты"; Key = "unitTests" },
    @{ Name = "политика актуализации тестов"; Key = "testMaintenance" }
)) {
    $section = Get-WorkflowSettingValue -Object $config -Name $suite.Key -Default $null
    if ($null -eq $section -or -not [bool](Get-WorkflowSettingValue -Object $section -Name "enabled" -Default $false)) {
        $disabledSuites += $suite.Name
    }
}
if ($disabledSuites.Count -gt 0) {
    Write-Host ""
    Write-Host "ВЫКЛЮЧЕНО настройками проекта, эта фаза их НЕ проверяет: $($disabledSuites -join ', ')."
    Write-Host ""
}

$sourceDirectory = Resolve-WorkflowPath -RepositoryRoot $repositoryRoot -Path ([string]$config.sourceDir)
$configurationFile = Join-Path $sourceDirectory "Configuration.xml"
$extensions = @(Get-WorkflowExtensions -RepositoryRoot $repositoryRoot -Config $config -AllowMissingOptional)
# Исполнитель кода стенда ставится между расширениями и сидом: сид проекта вправе
# им пользоваться. Поэтому при включённом исполнителе сид — отдельный шаг, как и
# при расширениях: внутри initializeScript он выполнился бы раньше исполнителя.
$standExecEnabled = Test-WorkflowStandExecEnabled -Config $config
$separateSeed = $extensions.Count -gt 0 -or $standExecEnabled
$v8Executable = Resolve-WorkflowV8Path -Config $config -V8Path $V8Path
$ccRoot = Resolve-Cc1CSkillsRoot -Config $config
$stateDirectory = Resolve-WorkflowPath -RepositoryRoot $repositoryRoot -Path ([string]$config.localStateDir)
$webUiConfig = if ($null -ne $config.PSObject.Properties["webUiTests"]) {
    $config.webUiTests
}
else {
    $null
}
$functionalConfig = if ($null -ne $config.PSObject.Properties["functionalTests"]) {
    $config.functionalTests
}
else {
    $null
}
$testMaintenanceConfig = if ($null -ne $config.PSObject.Properties["testMaintenance"]) {
    $config.testMaintenance
}
else {
    $null
}
$webUiEnabled = Test-WorkflowConfigFlag -Object $webUiConfig -Name "enabled"
$functionalTestsEnabled = Test-WorkflowConfigFlag -Object $functionalConfig -Name "enabled"
$testMaintenanceEnabled = Test-WorkflowConfigFlag -Object $testMaintenanceConfig -Name "enabled"
$runWebUi = [bool](
    $webUiEnabled -and (
        $IncludeWebUi -or
        ($RequireClean -and (Test-WorkflowConfigFlag -Object $webUiConfig -Name "requiredForReview"))
    )
)
if ($IncludeWebUi -and -not $webUiEnabled) {
    throw "Web UI tests were requested, but webUiTests.enabled is false or missing."
}
if ($runWebUi -and -not $functionalTestsEnabled) {
    throw "Web UI tests require functionalTests.enabled and an initialized test stand."
}
if ($runWebUi -and $SkipFunctionalTests) {
    throw "Web UI tests require the functional test stand. Remove -SkipFunctionalTests."
}

# HTTP-проверки включались ТОЛЬКО ключом -IncludeHttp, во всех фазах, включая
# Release. Для проекта с HTTP-сервисом это означало, что сервис не проверяется
# ничем обязательным: тесты написаны и лежат в репозитории, а исполняются лишь
# когда человек вспомнит про ключ. Правило «менять тесты вместе с HTTP-контрактом»
# при этом требовало писать то, что потом не запускается.
#
# Теперь обязательность объявляет манифест (functionalTests.httpRequired), а ключ
# остаётся принудительным включением для проекта, где флаг не выставлен.
$runHttp = [bool](
    $functionalTestsEnabled -and (
        $IncludeHttp -or (Test-WorkflowConfigFlag -Object $functionalConfig -Name "httpRequired")
    )
)
if ($IncludeHttp -and -not $functionalTestsEnabled) {
    throw "HTTP checks were requested, but functionalTests.enabled is false or missing."
}
# Пустой объём означает full: вызов, не указавший объём, получает полный прогон.
# Обратное решение — считать пустое значение выборочным — привело бы к тому, что
# любой забытый параметр молча уменьшает проверку.
$webUiScopeResolved = if ($WebUiScope) { $WebUiScope } else { "full" }

if ($runHttp -and $SkipFunctionalTests) {
    # Явный запрос несовместим с отказом от стенда — это ошибка вызова. Обязательность
    # из манифеста при -SkipFunctionalTests просто не действует: фаза Check намеренно
    # не поднимает стенд вовсе.
    if ($IncludeHttp) {
        throw "HTTP checks require the functional test stand. Remove -SkipFunctionalTests."
    }
    $runHttp = $false
}
$timestamp = "$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')-$PID"
$temporaryRoot = Join-Path $stateDirectory "preflight\$timestamp"
$basePath = Join-Path $temporaryRoot "base"
$functionalBasePath = Join-Path $temporaryRoot "functional-base"
$logDirectory = Join-Path $temporaryRoot "logs"
$temporaryCf = Join-Path $temporaryRoot "$($config.project)-preflight.cf"
# Переиспользуем отчёт вызывающего только если файл РЕАЛЬНО есть. Иначе путь
# остаётся своим, и проверка выполняется — несуществующий путь обязан стоить
# лишнего прогона, а не пропущенной проверки.
$reuseSourceIntegrity = [bool](
    $SourceIntegrityReport -and (Test-Path -LiteralPath $SourceIntegrityReport -PathType Leaf)
)
$sourceIntegrityReportPath = if ($reuseSourceIntegrity) {
    [System.IO.Path]::GetFullPath($SourceIntegrityReport)
}
else {
    Join-Path $stateDirectory "reports\source-integrity-$timestamp.json"
}
$reuseTestMaintenance = [bool](
    $TestMaintenanceReport -and (Test-Path -LiteralPath $TestMaintenanceReport -PathType Leaf)
)
$testMaintenanceReportPath = if ($reuseTestMaintenance) {
    [System.IO.Path]::GetFullPath($TestMaintenanceReport)
}
else {
    Join-Path $stateDirectory "reports\test-maintenance-$timestamp.json"
}
# Отчётов Web UI может быть два: прогоны идут разными шагами, и общий файл второй
# из них затёр бы. Разбор падения начинается с артефакта прогона — потерять отчёт
# первого шага значит потерять именно тот, ради которого он выполняется первым.
$webUiAffectedReportPath = Join-Path $stateDirectory "reports\web-ui-affected-$timestamp.json"
$webUiReportPath = Join-Path $stateDirectory "reports\web-ui-$timestamp.json"
if (-not $ReportPath) {
    $ReportPath = Join-Path $stateDirectory "reports\preflight-$timestamp.json"
}
$ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
[System.IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null
[System.IO.Directory]::CreateDirectory($logDirectory) | Out-Null

# Деревья прошлых прогонов подметаются ЗДЕСЬ, а не в конце своего прогона. В конце
# платформа ещё держит файл журнала, и удаление либо ждёт секундами, либо не
# проходит вовсе; к началу следующего прогона файл давно свободен. Уборка идёт без
# единой паузы, и то, что всё ещё занято, просто дождётся следующего раза.
$sweep = Clear-WorkflowTemporaryRoots `
    -Root (Split-Path $temporaryRoot -Parent) `
    -KeepFailed 1 `
    -AllowedRoot $stateDirectory `
    -KeepPath $temporaryRoot
if ($sweep.Removed -gt 0 -or $sweep.Kept -gt 0) {
    Write-Host "Временные деревья прошлых прогонов: удалено $($sweep.Removed), занято $($sweep.Kept)."
}

$steps = New-Object System.Collections.ArrayList
$extensionResults = New-Object System.Collections.ArrayList
$failure = $null
$cfHash = ""
$dirty = $false
# Первый прогон Web UI оставляет Apache поднятым, чтобы второй не публиковал стенд
# заново на том же порту. Признак нужен, чтобы убрать стенд, если фаза упала между
# прогонами и штатного второго шага не случилось.
$webUiApacheKept = $false
$headCommit = [string](
    (Invoke-WorkflowGit -RepositoryRoot $repositoryRoot -Arguments @("rev-parse", "HEAD")).Output |
        Select-Object -First 1
)
$branchName = Get-WorkflowBranchName -RepositoryRoot $repositoryRoot
# Отпечаток файлов рабочей копии. Коммита мало: незакоммиченная правка его не
# меняет, и прогон грязного дерева зачёлся бы чистому.
$fingerprint = Get-WorkflowFingerprint -RepositoryRoot $repositoryRoot

# Область сборки — вся копия, КРОМЕ сценариев Web UI. Сценарий не может изменить
# ни конфигурацию, ни данные стенда: он их только читает. Прежде правка одного
# .mjs стоила полной пересборки базы и стенда — минуты до первого теста, из-за
# чего проверки и запускались в обход фаз.
#
# Исключение, а не перечень включаемого: любой НОВЫЙ файл проекта обязан
# обесценивать кэш сам, без правки комплекта. Забытый в перечне путь отдал бы
# прогону базу от других исходников.
# Список «что не может изменить конфигурацию» ОДИН и тот же для проверки влияния
# и для кэша собранных баз. Порознь они разошлись: у кэша был только сьют Web UI,
# и правка документации или файла политики тестов пересобирала базу со стендом.
$buildEntries = Get-WorkflowFingerprintEntries `
    -RepositoryRoot $repositoryRoot `
    -ExcludePatterns (Get-WorkflowPlatformNeutralPatterns -Config $config -ForCache)
$buildFingerprint = Get-WorkflowFingerprintFromEntries -Entries $buildEntries
$buildCacheParts = @(
    [string]$config.platformVersion,
    [string](Get-WorkflowCc1CSkillsVersion -Cc1CSkillsRoot $ccRoot),
    (@($extensions | ForEach-Object { "$($_.name)=$($_.sourcePath)" }) -join ";")
)
# Имя для выделения стендов: устойчиво даже на detached HEAD.
$standBranch = Get-WorkflowStandBranchName -RepositoryRoot $repositoryRoot
$standAppName = Get-WorkflowStandAppName `
    -Config $config `
    -BranchName $standBranch `
    -DefaultAppName "$([string]$config.project)-functional-test"
$standHttpRange = Get-WorkflowStandPortRange -Config $config -BranchName $standBranch -Kind "http"
# Порт НЕ резервируется заранее. Ранняя попытка «занять» его была бесполезной:
# блокировка снималась сразу, а публикация происходила минутами позже, поэтому
# порт всё равно никем не удерживался. Хуже — исключение при подборе вылетало до
# формирования отчёта и до дешёвых проверок. Фактический порт выбирается ниже,
# под той же блокировкой, что и публикация, и уже удерживается поднятым Apache.
$standHttpPort = $standHttpRange.Start

try {
    Invoke-PreflightStep -Steps $steps -Name "git-state" -Action {
        $status = @(
            (Invoke-WorkflowGit -RepositoryRoot $repositoryRoot -Arguments @("status", "--porcelain")).Output
        )
        $script:dirty = $status.Count -gt 0
        if ($RequireClean -and $script:dirty) {
            throw "The working tree is not clean. Commit or stash changes before review/release preflight."
        }

        $trackedLocalFiles = @(
            (Invoke-WorkflowGit -RepositoryRoot $repositoryRoot -Arguments @(
                "ls-files", "--",
                ".v8-project.json",
                ".claude/settings.local.json",
                ".zcode/config.json"
            )).Output
        )
        if ($trackedLocalFiles.Count -gt 0) {
            throw "Local or secret-bearing files are tracked: $($trackedLocalFiles -join ', ')"
        }

        $mainRelation = Invoke-WorkflowGit `
            -RepositoryRoot $repositoryRoot `
            -Arguments @("merge-base", "--is-ancestor", "origin/$($config.mainBranch)", "HEAD") `
            -AllowFailure
        if ($mainRelation.ExitCode -ne 0) {
            throw "Current HEAD does not contain the locally fetched origin/$($config.mainBranch). Fetch and rebase/merge main first."
        }
    }

    # Целостность выгрузки проверяется до запуска платформы: маркеры конфликтов и
    # рассогласование Configuration.xml с файлами на диске дешевле поймать здесь,
    # чем на загрузке в базу, а «потерянный» при слиянии объект платформа вообще
    # не считает ошибкой.
    # Имя шага при переиспользовании ДРУГОЕ. Одинаковое имя означало бы, что по
    # составу шагов «проверено здесь» неотличимо от «проверено вызывающим», и
    # разбор отчёта пришлось бы вести догадками.
    if ($reuseSourceIntegrity) {
        Invoke-PreflightStep -Steps $steps -Name "source-integrity:reused" -Action {
            Write-Host "Целостность выгрузки уже проверена вызывающим: $sourceIntegrityReportPath"
        }
    }
    else {
        $sourceIntegrityScript = Join-Path $PSScriptRoot "Test-SourceIntegrity.ps1"
        $sourceIntegrityLog = Join-Path $logDirectory "source-integrity.log"
        Invoke-PreflightStep `
            -Steps $steps `
            -Name "source-integrity" `
            -LogPath $sourceIntegrityLog `
            -Action {
                Invoke-WorkflowPowerShell `
                    -ScriptPath $sourceIntegrityScript `
                    -Arguments @("-ReportPath", $sourceIntegrityReportPath) `
                    -LogPath $sourceIntegrityLog
            }
    }

    if ($testMaintenanceEnabled -and $reuseTestMaintenance) {
        Invoke-PreflightStep -Steps $steps -Name "test-maintenance:reused" -Action {
            Write-Host "Политика актуализации тестов уже выполнена вызывающим: $testMaintenanceReportPath"
        }
    }
    elseif ($testMaintenanceEnabled) {
        $testMaintenanceScript = Resolve-WorkflowPath `
            -RepositoryRoot $repositoryRoot `
            -Path ([string]$config.testMaintenance.script)
        $testMaintenanceLog = Join-Path $logDirectory "test-maintenance.log"
        Invoke-PreflightStep `
            -Steps $steps `
            -Name "test-maintenance" `
            -LogPath $testMaintenanceLog `
            -Action {
                Invoke-WorkflowPowerShell `
                    -ScriptPath $testMaintenanceScript `
                    -Arguments @("-ReportPath", $testMaintenanceReportPath) `
                    -LogPath $testMaintenanceLog
            }
    }

    $cfValidateScript = Resolve-CcSkillScript `
        -Cc1CSkillsRoot $ccRoot `
        -SkillName "cf-validate" `
        -ScriptName "cf-validate.ps1"
    $cfValidateLog = Join-Path $logDirectory "cf-validate.log"
    Invoke-PreflightStep -Steps $steps -Name "cf-validate" -LogPath $cfValidateLog -Action {
        Invoke-WorkflowPowerShell `
            -ScriptPath $cfValidateScript `
            -Arguments @("-ConfigPath", $sourceDirectory) `
            -LogPath $cfValidateLog
    }

    $cfeValidateScript = Resolve-CcSkillScript `
        -Cc1CSkillsRoot $ccRoot `
        -SkillName "cfe-validate" `
        -ScriptName "cfe-validate.ps1"
    foreach ($extension in $extensions) {
        $extensionValidateLog = Join-Path $logDirectory "cfe-validate-$($extension.name).log"
        Invoke-PreflightStep `
            -Steps $steps `
            -Name "cfe-validate:$($extension.name)" `
            -LogPath $extensionValidateLog `
            -Action {
                Invoke-WorkflowPowerShell `
                    -ScriptPath $cfeValidateScript `
                    -Arguments @("-ExtensionPath", ([string]$extension.sourcePath)) `
                    -LogPath $extensionValidateLog
            }
    }

    # Вид базы входит в ключ: с -CompileOnly структура БД не обновлялась, и
    # подменять одну другой нельзя — фаза, которой нужна применённая конфигурация,
    # получила бы базу, где её нет.
    $baseCacheKind = if ($CompileOnly) { "verification-loaded" } else { "verification-applied" }
    $baseCacheKey = Get-WorkflowBuiltBaseKey `
        -Kind $baseCacheKind `
        -Fingerprint $buildFingerprint `
        -Parts $buildCacheParts
    $baseRestored = $false
    $script:baseRestoredResult = $false
    if (-not $NoBuiltBaseCache) {
    Invoke-PreflightStep -Steps $steps -Name "db-from-cache" -Action {
        $script:baseRestoredResult = Restore-WorkflowBuiltBase `
            -StateDirectory $stateDirectory `
            -Kind $baseCacheKind `
            -Key $baseCacheKey `
            -TargetPath $basePath
        if ($script:baseRestoredResult) {
            Write-Host "Проверочная база взята из кэша: исходники те же, сборка не повторяется."
        }
        else {
            Write-Host "Проверочной базы для этих исходников в кэше нет — собираем."
            $difference = Compare-WorkflowFingerprintEntries `
                -Current $buildEntries `
                -Reference (Get-WorkflowBuiltBaseEntries -StateDirectory $stateDirectory -Kind $baseCacheKind)
            if ($difference.Compared) {
                # Отличий может не быть вовсе: тогда ключ разошёлся не из-за
                # исходников, а из-за платформы, версии навыков или состава
                # расширений — это тоже ответ, и он экономит поиск.
                Write-Host "  Отличий от последней собранной: $($difference.Total)."
                foreach ($pair in @(
                    @{ Label = "изменено"; Values = $difference.Changed },
                    @{ Label = "добавлено"; Values = $difference.Added },
                    @{ Label = "удалено"; Values = $difference.Removed })) {
                    foreach ($path in @($pair.Values)) {
                        Write-Host "       $($pair.Label): $path"
                    }
                }
            }
        }
    }
    }
    $baseRestored = [bool]$script:baseRestoredResult

    $createScript = Resolve-CcSkillScript `
        -Cc1CSkillsRoot $ccRoot `
        -SkillName "db-create" `
        -ScriptName "db-create.ps1"
    $createLog = Join-Path $logDirectory "db-create.log"
    if (-not $baseRestored) {
        Invoke-PreflightStep -Steps $steps -Name "db-create" -LogPath $createLog -Action {
            Invoke-WorkflowPowerShell `
                -ScriptPath $createScript `
                -Arguments @("-V8Path", $v8Executable, "-InfoBasePath", $basePath) `
                -LogPath $createLog
        }
    }

    # Проверка стоит ПЕРЕД загрузкой, а не после. Конфигурация из указателей Git
    # LFS грузится без единой ошибки: фазы проходят, тесты зелёные, а cf выходит
    # неполным — без картинок и двоичных частей, отличимый от верного только по
    # размеру. Обнаружился бы такой дефект у пользователя, которому не показали
    # картинку, и связать его с клоном без git-lfs было бы уже нечем.
    Assert-WorkflowSourcesMaterialized -SourcePath $sourceDirectory

    $loadScript = Resolve-CcSkillScript `
        -Cc1CSkillsRoot $ccRoot `
        -SkillName "db-load-xml" `
        -ScriptName "db-load-xml.ps1"
    $loadArguments = @(
        "-V8Path", $v8Executable,
        "-InfoBasePath", $basePath,
        "-ConfigDir", $sourceDirectory,
        "-Mode", "Full"
    )
    if (-not $CompileOnly) {
        $loadArguments += "-UpdateDB"
    }
    $loadLog = Join-Path $logDirectory "db-load-xml.log"
    $loadStepName = if ($CompileOnly) { "db-load-xml-compile-only" } else { "db-load-xml-update-db" }
    if (-not $baseRestored) {
        Invoke-PreflightStep -Steps $steps -Name $loadStepName -LogPath $loadLog -Action {
            Invoke-WorkflowPowerShell `
                -ScriptPath $loadScript `
                -Arguments $loadArguments `
                -LogPath $loadLog
        }
        # В кэш кладётся только база, собранная ЦЕЛИКОМ и без ошибки: запись
        # делается после загрузки, а не рядом с созданием.
        Invoke-PreflightStep -Steps $steps -Name "db-to-cache" -Action {
            Save-WorkflowBuiltBase `
                -StateDirectory $stateDirectory `
                -Kind $baseCacheKind `
                -Key $baseCacheKey `
                -SourcePath $basePath `
                -Entries $buildEntries `
                -Stamp @{
                    fingerprint = $buildFingerprint
                    platformVersion = [string]$config.platformVersion
                    branch = $branchName
                } | Out-Null
        }
    }


    foreach ($extension in $extensions) {
        $extensionLoadLog = Join-Path $logDirectory "db-load-extension-$($extension.name).log"
        Invoke-PreflightStep `
            -Steps $steps `
            -Name "db-load-extension:$($extension.name)" `
            -LogPath $extensionLoadLog `
            -Action {
                Invoke-WorkflowLoadExtension `
                    -Cc1CSkillsRoot $ccRoot `
                    -V8Executable $v8Executable `
                    -BasePath $basePath `
                    -Extension $extension `
                    -UpdateDB:(-not $CompileOnly) `
                    -LogPath $extensionLoadLog
            }
    }
    if (-not $CompileOnly -and $extensions.Count -gt 0) {
        $applicabilityLog = Join-Path $logDirectory "extensions-applicability.log"
        Invoke-PreflightStep `
            -Steps $steps `
            -Name "extensions-applicability" `
            -LogPath $applicabilityLog `
            -Action {
                Invoke-WorkflowCheckExtensions `
                    -V8Executable $v8Executable `
                    -BasePath $basePath `
                    -Extensions $extensions `
                    -LogPath $applicabilityLog
            }
    }

    # Выгрузка CF нужна выпуску и проверке точного коммита. На Compile она вдобавок
    # бессмысленна: база собрана без UpdateDBCfg, и выгружается из неё конфигурация,
    # которая к базе данных не применена.
    if ($CompileOnly -or $SkipCfDump) {
        # Путь обнуляем, чтобы вызывающий не принял за артефакт файл, которого нет.
        # Build-Release.ps1 читает temporaryCf из отчёта и обязан упасть внятно, а
        # не подобрать чужой CF от прошлого прогона.
        $temporaryCf = ""
        $reason = if ($CompileOnly) { "-CompileOnly: база собрана без UpdateDBCfg" } else { "-SkipCfDump" }
        Invoke-PreflightStep -Steps $steps -Name "db-dump-cf:skipped" -Action {
            Write-Host "Выгрузка CF пропущена ($reason). Артефакт нужен только фазам Verify и Release."
        }
    }
    else {
        $dumpScript = Resolve-CcSkillScript `
            -Cc1CSkillsRoot $ccRoot `
            -SkillName "db-dump-cf" `
            -ScriptName "db-dump-cf.ps1"
        $dumpLog = Join-Path $logDirectory "db-dump-cf.log"
        Invoke-PreflightStep -Steps $steps -Name "db-dump-cf" -LogPath $dumpLog -Action {
            Invoke-WorkflowPowerShell `
                -ScriptPath $dumpScript `
                -Arguments @(
                    "-V8Path", $v8Executable,
                    "-InfoBasePath", $basePath,
                    "-OutputFile", $temporaryCf
                ) `
                -LogPath $dumpLog
            $script:cfHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $temporaryCf).Hash.ToLowerInvariant()
        }
    }


    foreach ($extension in $extensions) {
        $temporaryCfe = Join-Path $temporaryRoot "$($extension.name)-preflight.cfe"
        $extensionDumpLog = Join-Path $logDirectory "db-dump-cfe-$($extension.name).log"
        Invoke-PreflightStep `
            -Steps $steps `
            -Name "db-dump-cfe:$($extension.name)" `
            -LogPath $extensionDumpLog `
            -Action {
                Invoke-WorkflowDumpExtension `
                    -Cc1CSkillsRoot $ccRoot `
                    -V8Executable $v8Executable `
                    -BasePath $basePath `
                    -Extension $extension `
                    -OutputFile $temporaryCfe `
                    -LogPath $extensionDumpLog
            }
        [void]$extensionResults.Add([pscustomobject]@{
            name = [string]$extension.name
            sourceDir = [string]$extension.sourceDir
            version = [string]$extension.version
            temporaryCfe = $temporaryCfe
            cfeSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $temporaryCfe).Hash.ToLowerInvariant()
        })
    }

    if (-not $SkipFunctionalTests -and $functionalTestsEnabled) {
        $initializeScript = Resolve-WorkflowPath `
            -RepositoryRoot $repositoryRoot `
            -Path ([string]$config.functionalTests.initializeScript)
        $smokeScript = Resolve-WorkflowPath `
            -RepositoryRoot $repositoryRoot `
            -Path ([string]$config.functionalTests.smokeScript)
        $seedScript = ""
        if ($separateSeed) {
            $seedProperty = $config.functionalTests.PSObject.Properties["seedScript"]
            if ($null -eq $seedProperty -or [string]::IsNullOrWhiteSpace([string]$seedProperty.Value)) {
                throw "functionalTests.seedScript is required when extensions or standExec are enabled. The initializer must support -SkipSeed so extensions and the stand executor can be installed before test data generation."
            }
            $seedScript = Resolve-WorkflowPath `
                -RepositoryRoot $repositoryRoot `
                -Path ([string]$seedProperty.Value)
        }
        if (-not (Test-Path -LiteralPath $initializeScript -PathType Leaf)) {
            throw "Functional test initializer was not found: $initializeScript"
        }
        if (-not (Test-Path -LiteralPath $smokeScript -PathType Leaf)) {
            throw "Functional smoke script was not found: $smokeScript"
        }
        if ($seedScript -and -not (Test-Path -LiteralPath $seedScript -PathType Leaf)) {
            throw "Functional test seed script was not found: $seedScript"
        }

        # Стенд — самый дорогой шаг фазы, и он детерминирован: те же исходники,
        # тот же оверлей, тот же сид дают ту же базу. Поэтому собранный стенд
        # кладётся в кэш и следующему прогону достаётся копией файла данных —
        # доли секунды вместо минут.
        #
        # В ключ входит ДЕНЬ: сид строит данные относительно текущей даты
        # (календари, периоды, сроки). Стенд вчерашней сборки содержал бы вчерашние
        # даты, и отчёт «с начала месяца» на границе месяца показал бы пустоту. Цена
        # — одна пересборка в сутки; ошибка в другую сторону стоит ложной проверки.
        #
        # Исполнитель стенда — часть стенда, но не проверочной базы: его признак
        # входит только в этот ключ. Иначе включение исполнителя сбрасывало бы и
        # кэш проверочной базы, в которой исполнителя нет.
        $standCacheKey = Get-WorkflowBuiltBaseKey `
            -Kind "functional-stand" `
            -Fingerprint $buildFingerprint `
            -Parts ($buildCacheParts + @((Get-Date).ToString("yyyy-MM-dd"), "stand-exec=$standExecEnabled"))
        $script:standRestoredResult = $false
        if (-not $NoBuiltBaseCache) {
        Invoke-PreflightStep -Steps $steps -Name "functional-stand-from-cache" -Action {
            $script:standRestoredResult = Restore-WorkflowBuiltBase `
                -StateDirectory $stateDirectory `
                -Kind "functional-stand" `
                -Key $standCacheKey `
                -TargetPath $functionalBasePath
            if ($script:standRestoredResult) {
                Write-Host "Функциональный стенд взят из кэша: исходники и подготовка данных те же."
            }
            else {
                Write-Host "Стенда для этих исходников в кэше нет — собираем."
                $difference = Compare-WorkflowFingerprintEntries `
                    -Current $buildEntries `
                    -Reference (Get-WorkflowBuiltBaseEntries -StateDirectory $stateDirectory -Kind "functional-stand")
                if ($difference.Compared) {
                    # Отличий может не быть вовсе: тогда ключ разошёлся не из-за
                    # исходников, а из-за платформы, версии навыков или состава
                    # расширений — это тоже ответ, и он экономит поиск.
                    Write-Host "  Отличий от последней собранной: $($difference.Total)."
                    foreach ($pair in @(
                        @{ Label = "изменено"; Values = $difference.Changed },
                        @{ Label = "добавлено"; Values = $difference.Added },
                        @{ Label = "удалено"; Values = $difference.Removed })) {
                        foreach ($path in @($pair.Values)) {
                            Write-Host "       $($pair.Label): $path"
                        }
                    }
                }
            }
        }
        }
        $standRestored = [bool]$script:standRestoredResult

        # Стенд несёт ТУ ЖЕ конфигурацию, что и проверочная база, плюс тестовый
        # оверлей. Собирать его отдельной полной загрузкой XML значит разобрать всю
        # конфигурацию второй раз за один прогон — на большой конфигурации это самая
        # дорогая строка фазы, и она удваивается.
        #
        # Поэтому база копируется, а адаптер догружает только своё. Гарантия не
        # страдает: копия сделана с базы, собранной из исходников ЭТОГО коммита
        # минуту назад, а не переиспользована с прошлого прогона.
        #
        # Два условия, без которых копировать нельзя:
        #   -CompileOnly — структура БД не обновлялась, копировать нечего;
        #   адаптер без ключа -SkipConfigurationLoad не умеет догружать оверлей в
        #   готовую базу и обязан собрать её сам.
        $functionalReuseBase = (
            -not $CompileOnly -and
            (Test-WorkflowScriptSupportsParameter `
                -ScriptPath $initializeScript `
                -ParameterName "SkipConfigurationLoad")
        )

        $standPlan = Get-WorkflowStandBuildPlan `
            -StandRestored $standRestored `
            -CanReuseVerificationBase $functionalReuseBase

        $functionalInitializeArguments = @(
            "-BasePath", $functionalBasePath,
            "-V8Path", $v8Executable,
            "-SkipRegistryUpdate"
        )
        if ($standPlan.CopyVerificationBase) {
            Copy-WorkflowFileInfoBase -SourcePath $basePath -TargetPath $functionalBasePath | Out-Null
            Write-Host "Функциональный стенд собирается из проверочной базы: полная загрузка не повторяется."
        }
        if ($standPlan.SkipConfigurationLoad) {
            $functionalInitializeArguments += "-SkipConfigurationLoad"
        }
        if ($standPlan.Recreate) {
            $functionalInitializeArguments += "-Recreate"
            if (-not $CompileOnly) {
                Write-Host "Адаптер не принимает -SkipConfigurationLoad: стенд собирается полной загрузкой."
            }
        }
        if ($separateSeed) {
            $functionalInitializeArguments += "-SkipSeed"
        }
        $functionalInitializeLog = Join-Path $logDirectory "functional-initialize.log"
        if ($standPlan.RunInitializer) {
            Invoke-PreflightStep `
                -Steps $steps `
                -Name $(if ($separateSeed) { "functional-stand-prepare" } else { "functional-data-generate" }) `
                 -LogPath $functionalInitializeLog `
                 -Action {
                    Invoke-WithPreservedLocalRegistry -RepositoryRoot $repositoryRoot -Action {
                        Invoke-WorkflowPowerShell `
                            -ScriptPath $initializeScript `
                            -Arguments $functionalInitializeArguments `
                            -LogPath $functionalInitializeLog
                    }
                }
        }

        # Администратор стенда — до любого подключения по имени и до первого запуска
        # предприятия: см. Initialize-WorkflowStandAdministrator. Шаг выполняется и
        # для стенда из кэша: снимок мог собрать комплект, ещё не знавший правила.
        Invoke-PreflightStep -Steps $steps -Name "functional-stand-administrator" -Action {
            $outcome = Initialize-WorkflowStandAdministrator -BasePath $functionalBasePath
            Write-Host "Администратор стенда: $outcome"
        }
        $functionalInfoBase = ConvertTo-WorkflowStandInfoBase -BasePath $functionalBasePath

        foreach ($extension in $extensions) {
            if ($standRestored) {
                break
            }
            $functionalExtensionLog = Join-Path $logDirectory "functional-load-extension-$($extension.name).log"
            Invoke-PreflightStep `
                -Steps $steps `
                -Name "functional-load-extension:$($extension.name)" `
                -LogPath $functionalExtensionLog `
                -Action {
                    Invoke-WorkflowLoadExtension `
                        -Cc1CSkillsRoot $ccRoot `
                        -V8Executable $v8Executable `
                        -InfoBase $functionalInfoBase `
                        -Extension $extension `
                        -UpdateDB `
                        -LogPath $functionalExtensionLog
                }
        }
        if ($extensions.Count -gt 0 -and -not $standRestored) {
            $functionalApplicabilityLog = Join-Path $logDirectory "functional-extensions-applicability.log"
            Invoke-PreflightStep `
                -Steps $steps `
                -Name "functional-extensions-applicability" `
                -LogPath $functionalApplicabilityLog `
                -Action {
                    Invoke-WorkflowCheckExtensions `
                        -V8Executable $v8Executable `
                        -InfoBase $functionalInfoBase `
                        -Extensions $extensions `
                        -LogPath $functionalApplicabilityLog
                }
        }

        # После расширений проекта — проверка применимости выше не должна видеть
        # исполнитель, он к проекту не относится, — и до сида.
        if ($standExecEnabled -and -not $standRestored) {
            $functionalStandExecLog = Join-Path $logDirectory "functional-stand-exec.log"
            Invoke-PreflightStep `
                -Steps $steps `
                -Name "functional-stand-exec" `
                -LogPath $functionalStandExecLog `
                -Action {
                    Install-WorkflowStandExec `
                        -RepositoryRoot $repositoryRoot `
                        -Config $config `
                        -Cc1CSkillsRoot $ccRoot `
                        -V8Executable $v8Executable `
                        -InfoBase $functionalInfoBase `
                        -StateDirectory $stateDirectory `
                        -LogPath $functionalStandExecLog
                }
        }

        if ($separateSeed -and -not $standRestored) {
            $functionalSeedLog = Join-Path $logDirectory "functional-seed.log"
            Invoke-PreflightStep `
                -Steps $steps `
                -Name "functional-data-generate" `
                -LogPath $functionalSeedLog `
                -Action {
                    Invoke-WorkflowPowerShell `
                        -ScriptPath $seedScript `
                        -Arguments @("-BasePath", $functionalBasePath) `
                        -LogPath $functionalSeedLog
                }
        }

        # В кэш стенд кладётся ПОСЛЕ всей сборки — оверлея, расширений и сида.
        # Запись на полпути отдала бы следующему прогону базу без данных, а пустой
        # стенд от правильного отличается только результатом тестов: проверки
        # прошли бы «успешно», ничего не проверив.
        if (-not $standRestored) {
            Invoke-PreflightStep -Steps $steps -Name "functional-stand-to-cache" -Action {
                Save-WorkflowBuiltBase `
                    -StateDirectory $stateDirectory `
                    -Kind "functional-stand" `
                    -Key $standCacheKey `
                    -SourcePath $functionalBasePath `
                    -Entries $buildEntries `
                    -Stamp @{
                        fingerprint = $buildFingerprint
                        platformVersion = [string]$config.platformVersion
                        branch = $branchName
                        seededOn = (Get-Date).ToString("yyyy-MM-dd")
                    } | Out-Null
            }
        }

        if ($runHttp) {
            $publishScript = Resolve-WorkflowPath `
                -RepositoryRoot $repositoryRoot `
                -Path ([string]$config.functionalTests.publishScript)
            $publishLog = Join-Path $logDirectory "functional-publish.log"
            Invoke-PreflightStep `
                -Steps $steps `
                -Name "functional-http-publish" `
                -LogPath $publishLog `
                -Action {
                    # Подбор порта и публикация — под одной блокировкой. Так порт
                    # переходит из «свободного» в «занятый Apache» без окна, в
                    # котором его мог бы выбрать другой worktree.
                    $script:standHttpPort = Invoke-WithWorkflowLock `
                        -Config $config `
                        -Name "stand-publish" `
                        -Action {
                            $candidate = Get-WorkflowFreePort `
                                -Config $config `
                                -StartPort $standHttpRange.Start `
                                -MaxPort $standHttpRange.End
                            # Out-Null обязателен: возвращаемый объект попал бы в
                            # поток успеха, и блокировка вернула бы массив вместо
                            # номера порта. Диагностика уже пишется в $publishLog.
                            Invoke-WorkflowPowerShell `
                                -ScriptPath $publishScript `
                                -Arguments @(
                                    "-BasePath", $functionalBasePath,
                                    "-V8Path", $v8Executable,
                                    "-AppName", $standAppName,
                                    "-Port", ([string]$candidate),
                                    "-SkipLock"
                                ) `
                                -LogPath $publishLog | Out-Null
                            # Сервисы расширений web-publish не публикует
                            # (known-issues, п. 12). Адаптер проекта может держать
                            # свой Apache — тогда VRD его забота; в Apache комплекта
                            # атрибут дописывается здесь.
                            $kitApache = Resolve-WorkflowPath `
                                -RepositoryRoot $repositoryRoot `
                                -Path ".build\workflow\http-apache"
                            $kitVrd = Join-Path $kitApache "publish\$standAppName\default.vrd"
                            if (Test-Path -LiteralPath $kitVrd -PathType Leaf) {
                                if (Set-WorkflowVrdExtensionServices -VrdPath $kitVrd) {
                                    Restart-WorkflowApache -ApachePath $kitApache
                                }
                            }
                            else {
                                Write-Host "Публикация адаптера — не в Apache комплекта: HTTP-сервисы расширений публикует он сам (publishExtensionsByDefault)."
                            }
                            Save-WorkflowStandPort `
                                -RepositoryRoot $repositoryRoot `
                                -Config $config `
                                -Kind "http" `
                                -BranchName $standBranch `
                                -Port $candidate
                            return $candidate
                        }
                }
        }

        # ── Web UI, шаг 1: то, что доказывает правку ─────────────────────────
        # План считается ДО функционального дыма, и первый прогон выполняется до
        # него же. Причина простая: тест разрабатываемой функциональности падает
        # чаще всего и стоит дешевле всего, а дым проверяет всё остальное. Пока
        # порядок был обратным, отказ по собственной правке приходил после полного
        # дыма — то есть дым оплачивался заранее и впустую.
        #
        # Артефакт изменённых объектов пишется ПЕРЕД любым прогоном: тест
        # 00-interface/03-changed-objects.test.mjs строит из него свои параметры
        # на этапе загрузки модуля. Без свежего артефакта он проверил бы список
        # предыдущего прогона — то есть молча не то.
        $webUiPlan = $null
        $webUiScript = ""
        $webUiSecondStage = $false
        $webUiAffectedRan = $false
        if ($runWebUi) {
            $webUiScript = Resolve-WorkflowPath `
                -RepositoryRoot $repositoryRoot `
                -Path ([string]$config.webUiTests.script)

            $changedTargetsScript = Join-Path $PSScriptRoot "Get-ChangedUiTargets.ps1"
            $changedTargetsLog = Join-Path $logDirectory "changed-ui-targets.log"
            $changedTargetsArguments = @()
            if ($WebUiBaseRef) {
                $changedTargetsArguments += @("-BaseRef", $WebUiBaseRef)
            }
            Invoke-PreflightStep `
                -Steps $steps `
                -Name "changed-ui-targets" `
                -LogPath $changedTargetsLog `
                -Action {
                    Invoke-WorkflowPowerShell `
                        -ScriptPath $changedTargetsScript `
                        -Arguments $changedTargetsArguments `
                        -LogPath $changedTargetsLog
                }

            # Отбор переиспользует отчёт политики, который к этому моменту уже
            # записан её шагом в начале preflight.
            $webUiPlan = Get-WebUiRunPlan `
                -Commit $headCommit `
                -Fingerprint $fingerprint `
                -RepositoryRoot $repositoryRoot `
                -Config $config `
                -Scope $webUiScopeResolved `
                -BaseRef $WebUiBaseRef `
                -PolicyReportPath $testMaintenanceReportPath `
                -PolicyReportReady $testMaintenanceEnabled
            $webUiSecondStage = [bool](
                $webUiPlan.FullRun -or @($webUiPlan.Smoke).Count -gt 0
            )

            if (@($webUiPlan.Affected).Count -gt 0) {
                # -KeepApache только когда за этим прогоном действительно идёт
                # второй. Иначе стенд остался бы поднятым после фазы: остановить
                # его было бы уже некому.
                Invoke-WebUiStage `
                    -Steps $steps `
                    -Name "web-ui-affected" `
                    -ScriptPath $webUiScript `
                    -Config $config `
                    -BasePath $functionalBasePath `
                    -V8Executable $v8Executable `
                    -StandBranch $standBranch `
                    -ReportPath $webUiAffectedReportPath `
                    -ArtifactsPath (Join-Path $stateDirectory "web-ui\runs\preflight-$timestamp\artifacts-affected") `
                    -LogPath (Join-Path $logDirectory "web-ui-affected.log") `
                    -Targets @($webUiPlan.Affected) `
                    -KeepApache:$webUiSecondStage
                $webUiAffectedRan = $true
                $script:webUiApacheKept = $webUiSecondStage
            }
        }

        # Модульные тесты идут ПЕРЕД дымом: они на порядок дешевле и проверяют
        # прикладную логику точечно, поэтому их отказ обязан приходить первым.
        #
        # Контур объявляется манифестом (unitTests.script), а не зашит в фазу:
        # движок модульного тестирования выбирает проект. Нет секции — шаг не
        # выполняется, и проект, ничего не настроивший, работает как раньше.
        $unitTestsConfig = Get-WorkflowSettingValue -Object $config -Name "unitTests" -Default $null
        if (Test-WorkflowConfigFlag -Object $unitTestsConfig -Name "enabled") {
            $unitScriptRelative = [string](Get-WorkflowSettingValue -Object $unitTestsConfig -Name "script" -Default "")
            if (-not $unitScriptRelative) {
                throw "unitTests.enabled is true, but unitTests.script is not set in .1c-workflow.json."
            }
            $unitScript = Resolve-WorkflowPath -RepositoryRoot $repositoryRoot -Path $unitScriptRelative
            if (-not (Test-Path -LiteralPath $unitScript -PathType Leaf)) {
                throw "Unit test runner was not found: $unitScript"
            }
            $unitReportPath = Join-Path $stateDirectory "reports\unit-tests-$timestamp.xml"
            $unitLog = Join-Path $logDirectory "unit-tests.log"
            Invoke-PreflightStep -Steps $steps -Name "unit-tests" -LogPath $unitLog -Action {
                Invoke-WorkflowPowerShell `
                    -ScriptPath $unitScript `
                    -Arguments @("-BasePath", $functionalBasePath, "-ReportPath", $unitReportPath) `
                    -LogPath $unitLog
            }
        }

        $smokeArguments = @("-BasePath", $functionalBasePath)
        if (-not $runHttp) {
            $smokeArguments += "-SkipHttp"
        }
        else {
            # URL задаём явно тем же значением, что опубликовали выше, чтобы
            # проверки не ушли на стенд другой ветки.
            #
            # Корень HTTP-сервиса берётся из манифеста, а не зашит в скрипт. Раньше
            # здесь стоял `hs/planner` — корень сервиса ЭТОГО проекта, и в шаблоне
            # переносимого комплекта он лежал в таком же виде: новый проект получил бы
            # чужой URL. Незаметно это было потому, что HTTP-проверки включались
            # только ключом и практически не запускались.
            $httpServiceRoot = [string](
                Get-WorkflowSettingValue -Object $functionalConfig -Name "httpServiceRoot" -Default ""
            )
            if (-not $httpServiceRoot) {
                throw "functionalTests.httpServiceRoot is not set in .1c-workflow.json, so the HTTP smoke URL cannot be built. Set it to the HTTP service root URL of this configuration."
            }
            $smokeArguments += @(
                "-ServiceUrl",
                "http://localhost:$standHttpPort/$standAppName/hs/$($httpServiceRoot.Trim('/'))"
            )
        }
        $smokeLog = Join-Path $logDirectory "functional-smoke.log"
        Invoke-PreflightStep -Steps $steps -Name "functional-smoke" -LogPath $smokeLog -Action {
            Invoke-WorkflowPowerShell `
                -ScriptPath $smokeScript `
                -Arguments $smokeArguments `
                -LogPath $smokeLog
        }

        # ── Web UI, шаг 2: обязательный минимум ──────────────────────────────
        # Выполняется только после успешного шага 1 и успешного дыма: любой из них
        # падает — Invoke-PreflightStep выбрасывает, и сюда управление не доходит.
        # Это и есть требуемое «нет смысла идти дальше»: fail-fast обеспечен
        # порядком шагов, а не отдельным флагом.
        if ($runWebUi) {
            $webUiArtifactsPath = Join-Path $stateDirectory "web-ui\runs\preflight-$timestamp\artifacts"
            $webUiLog = Join-Path $logDirectory "web-ui.log"
            if ($webUiPlan.FullRun -and @($webUiPlan.Targets).Count -eq 0) {
                # Весь сьют уже доказан на этом дереве. Шаг с ИМЕНЕМ, говорящим об
                # этом: пропуск без следа в отчёте читался бы как «Web UI не
                # выполнялся», а это разные вещи.
                Invoke-PreflightStep -Steps $steps -Name "web-ui-regression:reused" -Action {
                    Write-Host "Весь сьют зачтён прошлыми прогонами на этом же дереве."
                }
                $script:webUiApacheKept = $false
            }
            elseif ($webUiPlan.FullRun) {
                Invoke-WebUiStage `
                    -Steps $steps `
                    -Name "web-ui-regression" `
                    -ScriptPath $webUiScript `
                    -Config $config `
                    -BasePath $functionalBasePath `
                    -V8Executable $v8Executable `
                    -StandBranch $standBranch `
                    -ReportPath $webUiReportPath `
                    -ArtifactsPath $webUiArtifactsPath `
                    -LogPath $webUiLog `
                    -Targets @($webUiPlan.Targets) `
                    -ReuseApache:$webUiAffectedRan
                $script:webUiApacheKept = $false
            }
            elseif (@($webUiPlan.Smoke).Count -gt 0) {
                Invoke-WebUiStage `
                    -Steps $steps `
                    -Name "web-ui-smoke" `
                    -ScriptPath $webUiScript `
                    -Config $config `
                    -BasePath $functionalBasePath `
                    -V8Executable $v8Executable `
                    -StandBranch $standBranch `
                    -ReportPath $webUiReportPath `
                    -ArtifactsPath $webUiArtifactsPath `
                    -LogPath $webUiLog `
                    -Targets @($webUiPlan.Smoke) `
                    -ReuseApache:$webUiAffectedRan
                $script:webUiApacheKept = $false
            }
            elseif ($webUiAffectedRan) {
                # Имя шага другое намеренно. Зелёный `web-ui-smoke`, не запустивший
                # ни одного теста, читался бы как выполненный минимум — ровно та
                # неотличимость «проверено» от «проверено не то», против которой
                # объём прогона и пишется в отчёт.
                Invoke-PreflightStep -Steps $steps -Name "web-ui-smoke-covered" -Action {
                    Write-Host "Обязательный минимум smoke целиком вошёл в шаг web-ui-affected — отдельный прогон не требуется."
                }
            }
            else {
                # Не выполнено НИ ОДНОГО сценария. Это законно при объёме
                # `affected`: цикл разработки гоняет то, чего касается правка, а
                # правка могла не касаться интерфейса вовсе. Но сказать об этом
                # нужно вслух и другим именем шага: «покрыто прогоном затронутого»
                # здесь было бы прямой неправдой — затронутого прогона не было.
                Invoke-PreflightStep -Steps $steps -Name "web-ui-not-required" -Action {
                    Write-Host ("Web UI не выполнялся: объём '{0}', и политика не связала правку ни с одним сценарием." -f $webUiScopeResolved)
                    Write-Host "Обязательный минимум добавляет Verify, полный регресс — Release."
                }
            }
        }
    }
}
catch {
    $failure = $_
}

# Стенд, оставленный поднятым между двумя прогонами Web UI, штатно останавливает
# второй прогон. Если фаза упала до него — функциональным дымом или самим первым
# прогоном, — убрать стенд больше некому, и он висел бы на порту ветки до
# следующего запуска. Уборка не имеет права уронить фазу и не меняет её итог.
if ($webUiApacheKept) {
    try {
        $webUiApachePath = Join-Path $stateDirectory "web-ui\apache"
        if (Test-Path -LiteralPath (Join-Path $webUiApachePath "bin\httpd.exe") -PathType Leaf) {
            $webStopScript = Resolve-CcSkillScript `
                -Cc1CSkillsRoot $ccRoot `
                -SkillName "web-stop" `
                -ScriptName "web-stop.ps1"
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $webStopScript `
                -ApachePath $webUiApachePath | Out-Null
        }
    }
    catch {
        Write-Warning "Не удалось остановить стенд Web UI, оставленный между прогонами: $($_.Exception.Message)"
    }
}

$success = $null -eq $failure
$report = [pscustomobject]@{
    operation = "preflight"
    project = [string]$config.project
    branch = $branchName
    commit = $headCommit
    # Отпечаток файлов рабочей копии. Коммита мало: незакоммиченная правка его не
    # меняет, и прогон грязного дерева зачёлся бы чистому.
    fingerprint = $fingerprint
    dirty = [bool]$dirty
    success = $success
    # Релизопригодность требует ПОЛНОГО прогона сьюта, если сьют у проекта есть.
    # Иначе выборочный прогон выставлял бы тот же признак, что полный, и состояние
    # снова начало бы выглядеть проверенным полностью, не будучи таким — ровно тот
    # дефект, против которого это поле и вводилось.
    releaseReady = [bool](
        $success -and
        -not $CompileOnly -and
        (-not $webUiEnabled -or ($runWebUi -and $webUiScopeResolved -eq "full"))
    )
    compileOnly = [bool]$CompileOnly
    webUiIncluded = $runWebUi
    webUiScope = if ($runWebUi) { $webUiScopeResolved } else { "none" }
    # Записывается явно: по составу шагов «HTTP не проверялся» и «HTTP проверен»
    # выглядели одинаково, потому что при пропуске шаги просто отсутствовали.
    httpIncluded = $runHttp
    platformVersion = [string]$config.platformVersion
    # Фактическая, а не объявленная: объявленная — нижняя граница, и записать
    # её как версию прогона значило бы соврать ровно там, где отчёт нужен —
    # при разборе регрессии после смены тулчейна.
    cc1cSkillsVersion = Get-WorkflowCc1CSkillsVersion -Cc1CSkillsRoot $ccRoot
    cc1cSkillsVersionDeclared = [string]$config.cc1cSkillsVersion
    configurationVersion = Get-ConfigurationVersion -ConfigurationFile $configurationFile
    cfSha256 = $cfHash
    extensions = @($extensionResults)
    temporaryRoot = $temporaryRoot
    temporaryBase = $basePath
    temporaryCf = $temporaryCf
    sourceIntegrityReport = $sourceIntegrityReportPath
    testMaintenanceReport = $testMaintenanceReportPath
    # Сколько сценариев зачтено прошлыми прогонами и по каким отчётам. Без этих
    # полей `webUiScope: full` не отличить от полного прогона, выполненного здесь
    # и сейчас, — а это разные утверждения, даже когда объём совпадает.
    webUiReusedFiles = if ($runWebUi) { @($webUiPlan.Reused).Count } else { 0 }
    webUiReusedFrom = if ($runWebUi) { @($webUiPlan.ReusedFrom) } else { @() }
    webUiReport = if ($runWebUi) { $webUiReportPath } else { "" }
    # Отчёт первого прогона указывается отдельно и только когда он выполнялся.
    # Пустая строка здесь значит «затронутого по политике не нашлось», а не
    # «прогон был и отчёт потерян»: разбор падения начинается с артефакта, и
    # угадывать, какой из двух файлов искать, разработчик не должен.
    webUiAffectedReport = if ($runWebUi -and (Test-Path -LiteralPath $webUiAffectedReportPath -PathType Leaf)) {
        $webUiAffectedReportPath
    }
    else {
        ""
    }
    steps = @($steps)
    error = if ($failure) { $failure.Exception.Message } else { "" }
    completedAt = [DateTimeOffset]::Now.ToString("o")
}
Write-WorkflowJson -Value $report -Path $ReportPath | Out-Null

if (-not $success) {
    # Метка «этот прогон упал». По ней уборка следующего прогона сохранит дерево:
    # разбирать отказ без стенда, на котором он случился, нечем, а пересобрать его
    # дороже целого прогона.
    #
    # Пишется ДО сообщения о путях, чтобы не обещать сохранение, которого не было.
    $failedMarker = Join-Path $temporaryRoot (Get-WorkflowFailedRunMarkerName)
    Write-WorkflowJson -Value ([pscustomobject]@{
        failedAt = [DateTimeOffset]::Now.ToString("o")
        step = [string](@($steps | Where-Object { -not $_.success } | Select-Object -Last 1).name)
        message = [string]$failure.Exception.Message
        report = $ReportPath
    }) -Path $failedMarker | Out-Null

    Write-Host ""
    Write-Host "Стенд упавшего прогона ОСТАВЛЕН для разбора:"
    Write-Host "  каталог:              $temporaryRoot"
    Write-Host "  функциональный стенд: $functionalBasePath"
    Write-Host "  логи шагов:           $logDirectory"
    Write-Host "  Он переживёт следующий прогон; уберётся, когда упадёт следующий."
}

if ($success -and -not $KeepTemporaryFiles) {
    # Уборка не имеет права провалить успешный preflight: 1С освобождает файл журнала
    # не мгновенно, и на коротком прогоне удаление обгоняет освобождение. Логика с
    # повторами лежит в общей функции — вторая её копия здесь однажды разошлась с
    # копией в Build-Release.ps1, и выпуск упал на уборке уже собранного артефакта.
    Remove-WorkflowTemporaryTree `
        -Path $temporaryRoot `
        -AllowedRoot (Join-Path $stateDirectory "preflight") | Out-Null
}

# Выгруженный CF кладётся туда, где его найдут. Он лежал внутри временного дерева
# прогона под служебным именем: узнать путь можно было только из поля отчёта, а
# следующая фаза дерево сметала. Артефакт, за который уже заплачено сборкой,
# незачем терять — и незачем ради него запускать выпуск заново.
if ($temporaryCf -and (Test-Path -LiteralPath $temporaryCf -PathType Leaf)) {
    $keptCfDirectory = Join-Path $stateDirectory "cf"
    [System.IO.Directory]::CreateDirectory($keptCfDirectory) | Out-Null
    $shortCommit = if ($headCommit.Length -ge 7) { $headCommit.Substring(0, 7) } else { $headCommit }
    $keptCf = Join-Path $keptCfDirectory "$($report.project)_$($report.configurationVersion)_$shortCommit.cf"
    try {
        Copy-Item -LiteralPath $temporaryCf -Destination $keptCf -Force
        Write-Host ""
        Write-Host "Собранный CF: $keptCf"
        Write-Host ("Собран из коммита {0}, объём прогона Web UI — {1}." -f $shortCommit, $report.webUiScope)
        if (-not $report.releaseReady) {
            Write-Host "Это НЕ релизная сборка: releaseReady ставит только полный прогон фазой Release."
        }
    }
    catch {
        # Копия — удобство, а не результат фазы. Отказ здесь не должен ронять
        # прогон, который уже всё проверил.
        Write-Host "CF скопировать не удалось: $($_.Exception.Message)"
    }
}

# Разбор по времени печатается всегда, а не по ключу. Он нужен ровно тогда, когда
# его никто не просил: перерасход замечают, только если он на виду. Порог в
# секунду отсекает шум, не пряча ничего существенного.
$timed = @($steps | Where-Object { $null -ne $_.PSObject.Properties["durationSeconds"] })
if ($timed.Count -gt 0) {
    $total = ($timed | Measure-Object -Property durationSeconds -Sum).Sum
    Write-Host ""
    Write-Host ("Время шагов, всего {0:N0} с:" -f $total)
    foreach ($step in ($timed | Sort-Object -Property durationSeconds -Descending)) {
        if ($step.durationSeconds -lt 1) {
            continue
        }
        Write-Host ("  {0,7:N1} с  {1}" -f $step.durationSeconds, $step.name)
    }
    Write-Host ""
}

Write-Host "Preflight report: $ReportPath"
if ($CompileOnly -and $success) {
    Write-Warning "Compile-only preflight passed, but the result is not release-ready because UpdateDBCfg was skipped."
}
if (-not $success) {
    throw "Preflight failed: $($failure.Exception.Message). Report: $ReportPath"
}
Write-Host "Preflight completed successfully. Release ready: $($report.releaseReady)"
