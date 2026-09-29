<#
.SYNOPSIS
Проверки, не требующие платформы 1С. Единый источник истины для CI и разработчика.

.DESCRIPTION
Локальный preflight (`Test-Configuration.ps1`) требует установленной платформы 1С,
`cc-1c-skills` и файловой базы, поэтому на сервере он не запускается. Этот gate
собирает подмножество проверок, которые работают на любом Windows-раннере с Git и
PowerShell 5.1, и потому могут быть обязательными для каждого MR:

- целостность выгрузки (`Test-SourceIntegrity.ps1`): маркеры конфликтов,
  well-formed XML, согласованность Configuration.xml с файлами на диске;
- политика актуализации тестов (`Test-TestMaintenance.ps1`);
- формат уточнений правил разработки в `docs/rules/project`;
- валидность JSON-конфигурации проекта и шаблонов конфигов агентов;
- отсутствие персональных и секретоносных файлов в индексе;
- отсутствие CRLF в индексе (иначе правила .gitattributes нарушены);
- разбор всех PowerShell-скриптов проекта.

Gate НЕ заменяет локальные фазы `Compile`/`Selfcheck`/`Verify`: он не компилирует
конфигурацию, не выполняет UpdateDBCfg и не проверяет применимость расширений.

.PARAMETER BaseRef
База для сравнения в политике тестов. По умолчанию берётся из политики.

.PARAMETER ReportPath
Куда записать сводный JSON-отчёт.

.PARAMETER SkipTestMaintenance
Пропустить политику тестов (например, для запуска на самой main).

.PARAMETER SourceIntegrityReportPath
Куда положить отчёт проверки целостности выгрузки. Пусто — во временный файл.

.PARAMETER TestMaintenanceReportPath
Куда положить отчёт политики актуализации тестов. Пусто — во временный файл.

Оба параметра нужны фазе `Verify`: она выполняет gate, а затем preflight, и обе
эти проверки есть и там, и там. Указав пути явно, фаза передаёт готовые отчёты в
preflight, и работа выполняется один раз вместо двух.
#>
[CmdletBinding()]
param(
    [string]$BaseRef = "",
    [string]$ReportPath = "",
    [switch]$SkipTestMaintenance,
    [string]$SourceIntegrityReportPath = "",
    [string]$TestMaintenanceReportPath = ""
)

$ErrorActionPreference = "Stop"
$workflowDirectory = Join-Path (Split-Path $PSScriptRoot -Parent) "workflow"
. (Join-Path $workflowDirectory "Workflow.Common.ps1")

$repositoryRoot = Get-WorkflowRepositoryRoot -StartPath $PSScriptRoot
$config = Get-WorkflowConfig -RepositoryRoot $repositoryRoot
$stateDirectory = Resolve-WorkflowPath -RepositoryRoot $repositoryRoot -Path ([string]$config.localStateDir)
$timestamp = "$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')-$PID"
$logDirectory = Join-Path $stateDirectory "logs\ci-gate\$timestamp"
[System.IO.Directory]::CreateDirectory($logDirectory) | Out-Null
if (-not $ReportPath) {
    $ReportPath = Join-Path $stateDirectory "reports\ci-gate-$timestamp.json"
}

$steps = New-Object System.Collections.ArrayList
$failures = New-Object System.Collections.ArrayList

function Invoke-GateStep {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,

        [string]$LogPath = ""
    )

    Write-Host "==> $Name"
    try {
        & $Action | Out-Null
        [void]$script:steps.Add((New-WorkflowStepResult -Name $Name -Success $true -LogPath $LogPath))
        Write-Host "    OK"
    }
    catch {
        [void]$script:steps.Add(
            (New-WorkflowStepResult `
                -Name $Name `
                -Success $false `
                -ExitCode 1 `
                -LogPath $LogPath `
                -Message $_.Exception.Message)
        )
        [void]$script:failures.Add("${Name}: $($_.Exception.Message)")
        Write-Host "    FAILED: $($_.Exception.Message)"
    }
}

# ── 1. Персональные и секретоносные файлы не должны быть в индексе ─────────────
Invoke-GateStep -Name "no-local-files-tracked" -Action {
    $forbidden = @(
        ".v8-project.json",
        ".mcp.json",
        ".claude/settings.local.json",
        ".zcode/config.json"
    )
    $tracked = @(
        (Invoke-WorkflowGit `
            -RepositoryRoot $repositoryRoot `
            -Arguments (@("ls-files", "--") + $forbidden)).Output |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ($tracked.Count -gt 0) {
        throw "Local or secret-bearing files are tracked: $($tracked -join ', ')"
    }
}

# ── 2. Общие файлы правил обязаны быть в индексе ───────────────────────────────
function Test-TrackedPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    $tracked = @(
        (Invoke-WorkflowGit `
            -RepositoryRoot $script:repositoryRoot `
            -Arguments @("ls-files", "--", $RelativePath)).Output |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    return $tracked.Count -gt 0
}

Invoke-GateStep -Name "shared-rules-tracked" -Action {
    # Список намеренно узкий: сюда попадает только то, что гарантированно
    # создаётся установщиком процесса на ЛЮБОМ проекте. Файлы, специфичные для
    # конкретной команды (например .claude/settings.json), проверять нельзя —
    # иначе gate падает на свежем репозитории, где их и не должно быть.
    $required = @(
        "AGENTS.md",
        "CLAUDE.md",
        ".gitattributes",
        ".gitignore",
        ".1c-workflow.json",
        "docs/merge-conflicts.md",
        "docs/rules/README.md"
    )
    $missing = @()
    foreach ($path in $required) {
        if (-not (Test-TrackedPath -RelativePath $path)) {
            $missing += $path
        }
    }
    if ($missing.Count -gt 0) {
        throw "Shared rule files are missing from the repository: $($missing -join ', '). A new developer cannot reproduce the process without them."
    }

    # Регламент процесса называется по-разному в зависимости от того, как проект
    # был создан: docs/development.md в проекте-эталоне и
    # docs/1c-development-workflow.md после установки комплекта.
    $workflowDocs = @("docs/development.md", "docs/1c-development-workflow.md")
    $presentDocs = @($workflowDocs | Where-Object { Test-TrackedPath -RelativePath $_ })
    if ($presentDocs.Count -eq 0) {
        throw "No development workflow document is tracked. Expected one of: $($workflowDocs -join ', ')."
    }

    # Шаблоны, объявленные в parallel.agentConfigTemplates, обязаны существовать:
    # без них фаза Start не сможет собрать персональный конфиг агента.
    $parallelSettings = Get-WorkflowParallelSettings -Config $config
    foreach ($entry in @($parallelSettings.agentConfigTemplates)) {
        $template = [string](Get-WorkflowSettingValue -Object $entry -Name "template" -Default "")
        if (-not $template) {
            continue
        }
        if (-not (Test-TrackedPath -RelativePath $template)) {
            throw "Agent config template '$template' is declared in .1c-workflow.json but is not tracked in Git."
        }
    }
}

# ── 2a. Уточнения правил разработки оформлены по формату ──────────────────────
# Общие правила лежат в docs/rules и входят в замок установки: их правка по месту
# падает шагом process-files-unmodified. Особенности конфигурации живут рядом, в
# docs/rules/project, и в замок не входят.
#
# Связь уточнения с базовым правилом — по имени файла, и держится она только на
# заголовке внутри файла. Без проверки заголовка overlay через год превращается в
# набор файлов, про которые никто не помнит, что именно они переопределяют и зачем:
# отсутствие поля «Причина» неотличимо от правила, причина которого забыта.
Invoke-GateStep -Name "rules-overlay-valid" -Action {
    $overlay = Get-WorkflowRulesOverlayProblems -RepositoryRoot $repositoryRoot
    if (@($overlay.Problems).Count -gt 0) {
        throw "Уточнения правил оформлены неверно ($(@($overlay.Problems).Count)). Формат описан в docs/rules/project/README.md:`n  $(@($overlay.Problems) -join "`n  ")"
    }
    if ($overlay.Checked -eq 0) {
        Write-Host "    уточнений нет, проверять нечего"
        return
    }
    Write-Host "    проверено уточнений: $($overlay.Checked)"
}

# ── 2b. Файлы контракта закрыты владельцем ────────────────────────────────────
# CODEOWNERS — единственное место во всей схеме, где круг «проверку меняет тот,
# кого она проверяет» разомкнут: GitLab читает файл из ЦЕЛЕВОЙ ветки, поэтому
# ослабить владельцев в своём же MR, чтобы этот MR прошёл, нельзя.
#
# Круг размыкается только если файл действует, а действует он не всегда.
# Правило с несуществующим пользователем GitLab игнорирует МОЛЧА, и такой файл
# неотличим от работающего: он есть, он выглядит заполненным, и он ничего не
# защищает. То же даёт забытый владелец и оставшаяся заглушка установщика.
Invoke-GateStep -Name "codeowners-covers-contract" -Action {
    $owners = Get-WorkflowCodeOwnersProblems -RepositoryRoot $repositoryRoot
    if (-not $owners.Present) {
        # Не отказ: CODEOWNERS ставится только вместе с -CodeOwner, а проект
        # может жить не в GitLab. Но и не молчание — иначе отсутствие защиты
        # выглядит как её наличие.
        Write-Host "    .gitlab/CODEOWNERS нет: файлы контракта не закрыты владельцем"
        return
    }
    if (@($owners.Problems).Count -gt 0) {
        throw ("Владельцы файлов контракта объявлены неверно ($(@($owners.Problems).Count)). " +
            "Пока правило не действует, защита только выглядит существующей:`n  " +
            ($owners.Problems -join "`n  "))
    }
    Write-Host "    правил: $($owners.Rules), путей контракта проверено: $($owners.Checked)"
}

# ── 3. Только rebase: merge-коммитов в ветке быть не должно ───────────────────
# Правило «интегрировать origin/main через rebase» было чисто декларативным,
# хотя проверяется одной командой. Проверяем только когда есть с чем сравнивать.
if ($BaseRef) {
    Invoke-GateStep -Name "rebase-only" -Action {
        $baseCheck = Invoke-WorkflowGit `
            -RepositoryRoot $repositoryRoot `
            -Arguments @("rev-parse", "--verify", $BaseRef) `
            -AllowFailure
        if ($baseCheck.ExitCode -ne 0) {
            throw "Base ref was not found: $BaseRef. Fetch the repository first."
        }
        $merges = @(
            (Invoke-WorkflowGit `
                -RepositoryRoot $repositoryRoot `
                -Arguments @("log", "--merges", "--format=%h %s", "$BaseRef..HEAD")).Output |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
        if ($merges.Count -gt 0) {
            $sample = @($merges | Select-Object -First 3)
            throw "$($merges.Count) merge commit(s) found between $BaseRef and HEAD. Integrate the main branch with 'git rebase', not 'git merge': $($sample -join ' | ')"
        }
    }
}

# ── 3a. Настройки не стали слабее, чем в базовой ветке ────────────────────────
# Замок установки стережёт файлы ПРОЦЕССА. Манифест проекта в него не входит и
# входить не должен: приспосабливать его под конфигурацию и есть нормальная
# работа. Остаётся дыра, которую не закрывает ничто: выключенная регрессия,
# объём release, опущенный до выборочного, processDevelopment — ни один из этих
# случаев не ломает ни одной фазы. Они делают фазу зелёной ДЕШЕВЛЕ, и поэтому их
# не замечают: в diff это настройка, а не снятая проверка.
#
# Требовать конкретных значений комплект не может: у свежего проекта регрессия
# законно выключена, пока он её не завёл. Поэтому проверяется не значение, а
# НАПРАВЛЕНИЕ — планку задаёт сам проект тем, что уже влил, а шаг стережёт
# только её понижение. Такое правило не настраивается и не устаревает.
if ($BaseRef) {
    Invoke-GateStep -Name "settings-not-weakened" -Action {
        $baseManifest = Invoke-WorkflowGit `
            -RepositoryRoot $repositoryRoot `
            -Arguments @("show", "${BaseRef}:.1c-workflow.json") `
            -AllowFailure
        if ($baseManifest.ExitCode -ne 0) {
            Write-Host "    манифеста нет в $BaseRef, сравнивать не с чем"
            return
        }

        $baseText = (@($baseManifest.Output) -join "`n").TrimStart([char]0xFEFF)
        if ([string]::IsNullOrWhiteSpace($baseText)) {
            Write-Host "    манифест в $BaseRef пуст, сравнивать не с чем"
            return
        }
        $baseConfig = $baseText | ConvertFrom-Json

        $weakenings = @(Get-WorkflowContractWeakenings -BaseConfig $baseConfig -HeadConfig $config)
        $undeclared = @($weakenings | Where-Object { -not $_.Approved })

        foreach ($declaredWeakening in @($weakenings | Where-Object { $_.Approved })) {
            Write-Host ("    ОСЛАБЛЕНО ОСОЗНАННО: $($declaredWeakening.Setting) " +
                "$($declaredWeakening.From) -> $($declaredWeakening.To); " +
                "решение $($declaredWeakening.DecidedBy): $($declaredWeakening.Reason)")
        }

        if ($undeclared.Count -gt 0) {
            $details = @($undeclared | ForEach-Object { "$($_.Setting): $($_.From) -> $($_.To)" })
            throw ("Настройки стали слабее, чем в ${BaseRef} ($($undeclared.Count)). " +
                "Проверка, снятая настройкой, не роняет ни одной фазы — она делает их зелёными дешевле:`n  " +
                ($details -join "`n  ") +
                "`n  Осознанное понижение объявляется в .1c-workflow.json массивом contractWeakening " +
                "с полями setting, reason и decidedBy — тогда оно видно в diff и проходит через владельца.")
        }

        if ($weakenings.Count -eq 0) {
            Write-Host "    ослаблений нет"
        }
    }
}

# ── 4. Слияние доведено до конца ──────────────────────────────────────────────
# Файл в состоянии conflict попадает в индекс без маркеров, если его «разрешили»
# редактором, но не сняли с конфликта. Проверяется одной командой.
# Новый объект метаданных не покрыт ничем по определению: существующие проверки
# его не знают, а на стенде для него нет данных. Отчёт, уехавший пользователю
# пустым, — ровно этот случай: «сформировался без ошибки» прошло, потому что
# пустой результат от правильного эта проверка не отличает.
#
# Шаг работает только когда есть с чем сравнивать: без базы сравнения понятия
# «добавлен» не существует.
if ($BaseRef) {
    Invoke-GateStep -Name "new-objects-have-tests" -Action {
        # Путевое правило политики — «изменился какой-нибудь файл в tests/» —
        # отличить покрытие НОВОГО объекта от правки постороннего теста не может.
        # На живой правке это и вышло: тест постраничности зачёлся как покрытие
        # новой очереди обогащения, и очередь осталась без единой проверки при
        # зелёном гейте.
        #
        # Здесь проверяется упоминание имени объекта в тексте изменённых тестов.
        # Эвристика честно слабее, чем «тест действительно проверяет объект»:
        # написать имя в комментарии никто не мешает. Но она ловит то, ради чего
        # заводится, — объект, о котором тесты не знают вовсе.
        # Поднадзорны ВСЕ виды, кроме перечисленных исключений. Белый список
        # молча освобождал от проверки всё, что в него не попало: новая константа
        # и новое регламентное задание проходили гейт как «новых объектов нет».
        $addedPaths = @(Get-WorkflowAddedPaths -RepositoryRoot $repositoryRoot -BaseRef $BaseRef)
        $newObjects = @(
            Get-WorkflowAddedMetadataObjects `
                -AddedPaths $addedPaths `
                -SourceRelativePath ([string]$config.sourceDir) `
                -ExcludeKinds (Get-WorkflowKindsExemptFromTests -Config $config)
        )
        if ($newObjects.Count -eq 0) {
            Write-Host "    новых объектов метаданных нет"
            return
        }

        $changedPaths = @(Get-WorkflowChangedPaths -RepositoryRoot $repositoryRoot -BaseRef $BaseRef)
        $testContents = New-Object System.Collections.ArrayList
        foreach ($path in $changedPaths) {
            $normalized = ([string]$path).Replace([char]92, [char]47)
            if (-not $normalized.StartsWith("tests/")) {
                continue
            }
            $full = Join-Path $repositoryRoot ($normalized -replace '/', '\')
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
                continue
            }
            [void]$testContents.Add((Get-Content -Raw -LiteralPath $full -Encoding UTF8))
        }

        $without = @(
            Find-WorkflowObjectsWithoutTests -Objects $newObjects -TestContents @($testContents)
        )
        if ($without.Count -eq 0) {
            Write-Host "    новых объектов: $($newObjects.Count), все упомянуты в изменённых тестах"
            return
        }

        throw ("Новые объекты метаданных не упомянуты ни в одном изменённом тесте: " +
            "$($without -join ', '). Новый объект не покрыт существующими проверками по " +
            "определению: они о нём не знают. Правка постороннего теста таким покрытием не является.")
    }

    Invoke-GateStep -Name "new-objects-have-fixtures" -Action {
        $added = @(Get-WorkflowAddedPaths -RepositoryRoot $repositoryRoot -BaseRef $BaseRef)
        $changed = @(Get-WorkflowChangedPaths -RepositoryRoot $repositoryRoot -BaseRef $BaseRef)

        # Узкий список видов: фикстуры нужны тому, что ПОКАЗЫВАЮТ. Служебный
        # регистр показывать нечем, и его правильное состояние на стенде — пусто.
        $newObjects = @(
            Get-WorkflowAddedMetadataObjects `
                -AddedPaths $added `
                -SourceRelativePath ([string]$config.sourceDir) `
                -Kinds (Get-WorkflowKindsRequiringFixtures)
        )
        if ($newObjects.Count -eq 0) {
            Write-Host "    новых объектов, которым нужны данные стенда, нет"
            return
        }

        $fixturePaths = @(
            Get-WorkflowSettingValue -Object $config.functionalTests -Name "fixturePaths" -Default @()
        )
        if (Test-WorkflowFixturesTouched -ChangedPaths $changed -FixturePaths $fixturePaths) {
            Write-Host "    новых объектов: $($newObjects.Count), подготовка данных стенда изменена"
            return
        }

        if ($fixturePaths.Count -eq 0) {
            throw ("Появились новые объекты метаданных ($($newObjects -join ', ')), " +
                "но проект не объявил, чем готовятся данные стенда. " +
                "Укажите functionalTests.fixturePaths в .1c-workflow.json: без данных новый объект " +
                "не на чем показать, и проверка «сформировалось без ошибки» пройдёт на пустом результате.")
        }
        throw ("Появились новые объекты метаданных ($($newObjects -join ', ')), " +
            "а подготовка данных стенда не менялась ($($fixturePaths -join ', ')). " +
            "Новый объект не покрыт существующими проверками и без фикстур не проверяем: " +
            "пустой результат неотличим от правильного.")
    }
}

Invoke-GateStep -Name "new-objects-in-subsystem" -Action {
    $added = @(Get-WorkflowAddedPaths -RepositoryRoot $repositoryRoot -BaseRef $BaseRef)
    $newObjects = @(
        Get-WorkflowAddedMetadataObjects `
            -AddedPaths $added `
            -SourceRelativePath ([string]$config.sourceDir) `
            -Kinds (Get-WorkflowKindsRequiringSubsystem -Config $config)
    )
    if ($newObjects.Count -eq 0) {
        Write-Host "    новых объектов, которым нужна подсистема, нет"
        return
    }

    $sourcePath = Resolve-WorkflowPath -RepositoryRoot $repositoryRoot -Path ([string]$config.sourceDir)
    $membership = Get-WorkflowSubsystemMembership -SourcePath $sourcePath
    $exempt = @(
        Get-WorkflowSettingValue `
            -Object (Get-WorkflowSettingValue -Object $config -Name "subsystemMembership" -Default $null) `
            -Name "exempt" -Default @()
    )
    $outside = @(Find-WorkflowObjectsOutsideSubsystems -Objects $newObjects -Membership $membership -Exempt $exempt)
    if ($outside.Count -eq 0) {
        Write-Host "    новых объектов: $($newObjects.Count), все входят в подсистемы"
        return
    }

    throw ("Новые объекты не входят ни в одну подсистему: $($outside -join ', '). " +
        "Такой объект не виден в интерфейсе, его не открывает проверка команд и не находит " +
        "человек — он существует только в конфигураторе. Добавьте его в подсистему навыком " +
        "subsystem-edit либо перечислите в subsystemMembership.exempt, если он служебный.")
}

Invoke-GateStep -Name "user-help-for-new-objects" -Action {
    # Справка по F1 живёт внутри конфигурации: пользователь читает её там, где
    # работает, и без доступа к репозиторию и вики. Требование поднимается на
    # НОВЫХ объектах тех видов, которые пользователь открывает; массовой
    # дозаписи старым правило не требует — это отдельная работа.
    $helpSettings = Get-WorkflowUserHelpSettings -Config $config
    if (-not $helpSettings.Enabled) {
        Write-Host "    требование справки выключено проектом (userHelp.enabled)"
        return
    }

    $added = @(Get-WorkflowAddedPaths -RepositoryRoot $repositoryRoot -BaseRef $BaseRef)
    $coverage = Get-WorkflowNewUserHelpCoverage `
        -RepositoryRoot $repositoryRoot `
        -Config $config `
        -AddedPaths $added `
        -Kinds $helpSettings.Kinds `
        -Languages $helpSettings.Languages
    if ($coverage.Total -eq 0) {
        Write-Host "    новых объектов, которым нужна справка, нет"
        return
    }

    $without = @($coverage.Missing)
    if ($without.Count -eq 0) {
        Write-Host "    новых объектов: $($coverage.Total), справка есть у всех"
        return
    }

    throw ("Новые объекты без встроенной справки: $($without -join ', '). Пользователь " +
        "нажмёт F1 и не получит ничего. Добавьте справку навыком help-add из cc-1c-skills: " +
        "что это в терминах предметной области, зачем заполнять и чего делать нельзя. " +
        "Пересказ полей формы справкой не считается — он уже есть на форме.")
}

Invoke-GateStep -Name "new-scheduled-jobs-have-update-handler" -Action {
    # Добавленное регламентное задание в базе ВЫКЛЮЧЕНО и без расписания.
    # «Объект есть» и «задание работает» — разные состояния, и зелёный прогон
    # подтверждает только первое: обработчик обновления, который включает
    # задание и задаёт ему расписание, не проверяется ничем.
    $added = @(Get-WorkflowAddedPaths -RepositoryRoot $repositoryRoot -BaseRef $BaseRef)
    $newJobs = @(
        Get-WorkflowAddedMetadataObjects `
            -AddedPaths $added `
            -SourceRelativePath ([string]$config.sourceDir) `
            -Kinds @("ScheduledJobs")
    )
    if ($newJobs.Count -eq 0) {
        Write-Host "    новых регламентных заданий нет"
        return
    }

    $changed = @(Get-WorkflowChangedPaths -RepositoryRoot $repositoryRoot -BaseRef $BaseRef)
    $source = ([string]$config.sourceDir).Replace([char]92, [char]47).Trim([char]47)

    # Текст ищется отдельно в коде и отдельно в тестах: включение задания пишут в
    # обработчике обновления, а доказывает его тест. Один без другого ничего не
    # значит — код без теста не проверен, тест без кода проверять нечего.
    $handlerTexts = New-Object System.Collections.ArrayList
    $testTexts = New-Object System.Collections.ArrayList
    foreach ($path in $changed) {
        $normalized = ([string]$path).Replace([char]92, [char]47)
        $full = Join-Path $repositoryRoot ($normalized -replace '/', [string][char]92)
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            continue
        }
        if ($normalized.StartsWith("$source/") -and $normalized.EndsWith(".bsl")) {
            [void]$handlerTexts.Add((Get-Content -Raw -LiteralPath $full -Encoding UTF8))
        }
        elseif ($normalized.StartsWith("tests/")) {
            [void]$testTexts.Add((Get-Content -Raw -LiteralPath $full -Encoding UTF8))
        }
    }

    $withoutHandler = @()
    $withoutTest = @()
    foreach ($job in $newJobs) {
        $name = @(([string]$job).Split([char]47))[-1]
        if (@($handlerTexts | Where-Object { $_ -and $_.Contains($name) }).Count -eq 0) {
            $withoutHandler += $name
        }
        if (@($testTexts | Where-Object { $_ -and $_.Contains($name) }).Count -eq 0) {
            $withoutTest += $name
        }
    }

    if ($withoutHandler.Count -eq 0 -and $withoutTest.Count -eq 0) {
        Write-Host "    новых заданий: $($newJobs.Count), у всех есть обработчик обновления и тест"
        return
    }

    $parts = @()
    if ($withoutHandler.Count -gt 0) {
        $parts += "без обработчика обновления: $($withoutHandler -join ', ')"
    }
    if ($withoutTest.Count -gt 0) {
        $parts += "без теста: $($withoutTest -join ', ')"
    }
    throw ("Новое регламентное задание $($parts -join '; '). Добавленное задание в базе " +
        "выключено и без расписания, поэтому обработчик обновления обязан его включить и " +
        "задать расписание, а тест — это подтвердить. Проверка смотрит, что оба места " +
        "упоминают задание; утверждать про включение и расписание должен сам тест.")
}

Invoke-GateStep -Name "no-unmerged-paths" -Action {
    $unmerged = @(
        (Invoke-WorkflowGit `
            -RepositoryRoot $repositoryRoot `
            -Arguments @("-c", "core.quotePath=false", "ls-files", "-u")).Output |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ($unmerged.Count -gt 0) {
        $paths = @(
            $unmerged | ForEach-Object { ($_ -split '\t', 2)[-1].Trim() } | Select-Object -Unique
        )
        throw "$($paths.Count) path(s) are still in a conflicted state in the index: $(@($paths | Select-Object -First 5) -join ', '). Finish the merge with 'git add' on each resolved path."
    }
}

# ── 5. Нормализация переводов строк соблюдена ─────────────────────────────────
# Проверок две, и они о разном. Первая: у файлов, которые git нормализует,
# хранимый вид должен этому соответствовать. Вторая: файлы выгрузки 1С не должны
# нормализоваться вовсе — в них перевод строки бывает данными.
$eolLines = @(
    (Invoke-WorkflowGit `
        -RepositoryRoot $repositoryRoot `
        -Arguments @("-c", "core.quotePath=false", "ls-files", "--eol")).Output
)

Invoke-GateStep -Name "index-eol-normalized" -Action {
    $offenders = @(Select-WorkflowEolOffenders -Lines $eolLines)
    if ($offenders.Count -gt 0) {
        $sample = @($offenders | Select-Object -First 5)
        throw ("$($offenders.Count) file(s) have CRLF or mixed line endings in the index " +
            "although .gitattributes has git normalize them. Run 'git add --renormalize .'. " +
            "Examples: $($sample -join ', ')")
    }
}

Invoke-GateStep -Name "dump-files-not-eol-converted" -Action {
    # Пути берутся из настроек, а не перечисляются здесь: у каждого проекта свой
    # каталог выгрузки и свой состав расширений, и проверка, знающая только
    # чужие имена каталогов, молча не проверяет ничего.
    $sourcePrefixes = @([string]$config.sourceDir)
    foreach ($extension in @(Get-WorkflowExtensions -RepositoryRoot $repositoryRoot -Config $config -AllowMissingOptional)) {
        $sourcePrefixes += [string]$extension.sourceDir
    }

    $converted = Select-WorkflowConvertedDumpFiles -Lines $eolLines -SourcePrefixes $sourcePrefixes
    if ($converted.Count -eq 0) {
        Write-Host "    выгрузка хранится без преобразования концов строк"
        return
    }

    throw ("$($converted.Count) файл(ов) выгрузки git нормализует по концам строк, " +
        "например $(@($converted.Examples) -join ', '). В выгрузке перевод строки бывает " +
        "данными — представление в две строки, картинка SVG, текстовый макет, текст " +
        "ограничения доступа, — и нормализация портит их незаметно: правок нет, а " +
        "собранный cf расходится с базой и Конфигуратор показывает изменённой всю " +
        "конфигурацию. Задайте в .gitattributes '-text diff merge' для *.xml, *.html, " +
        "*.txt, *.svg и выполните один раз: git add --renormalize .")
}

# ── 6. JSON-конфигурация проекта валидна ──────────────────────────────────────
Invoke-GateStep -Name "json-config-valid" -Action {
    # ОБЯЗАТЕЛЬНЫЕ: создаются установщиком на любом проекте. Поставка настроек
    # проверяется наравне с файлом проекта: она читается при каждом чтении
    # настроек, и битый JSON в ней роняет всё, а не один шаг.
    $requiredJson = @(".1c-workflow.json", ".1c-workflow.defaults.json")
    $policyPath = [string](
        Get-WorkflowSettingValue -Object $config.testMaintenance -Name "policy" -Default ""
    )
    if ($policyPath) {
        $requiredJson += $policyPath
    }
    foreach ($entry in @((Get-WorkflowParallelSettings -Config $config).agentConfigTemplates)) {
        $template = [string](Get-WorkflowSettingValue -Object $entry -Name "template" -Default "")
        if ($template) {
            $requiredJson += $template
        }
    }

    # НЕОБЯЗАТЕЛЬНЫЕ: проверяются на валидность, только если присутствуют.
    # Здесь нельзя требовать существования: .claude/settings.json специфичен для
    # команды и установщиком не создаётся, а .v8-project.example.json появляется
    # лишь на проектах, где реестр баз ведётся шаблоном. Требование существования
    # ломало приёмку свежего репозитория — тот же дефект, что в shared-rules.
    $optionalJson = @(
        ".claude/settings.json",
        ".v8-project.example.json"
    )

    foreach ($relative in @($requiredJson | Where-Object { $_ } | Select-Object -Unique)) {
        $path = Resolve-WorkflowPath -RepositoryRoot $repositoryRoot -Path $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Required JSON file is missing: $relative"
        }
        try {
            Get-Content -Raw -LiteralPath $path -Encoding UTF8 | ConvertFrom-Json | Out-Null
        }
        catch {
            throw "Invalid JSON in ${relative}: $($_.Exception.Message)"
        }
    }
    foreach ($relative in $optionalJson) {
        $path = Resolve-WorkflowPath -RepositoryRoot $repositoryRoot -Path $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            continue
        }
        try {
            Get-Content -Raw -LiteralPath $path -Encoding UTF8 | ConvertFrom-Json | Out-Null
        }
        catch {
            throw "Invalid JSON in ${relative}: $($_.Exception.Message)"
        }
    }
    # Секция parallel должна быть непротиворечивой: конструктор бросит исключение
    # на пересекающихся диапазонах и слишком маленьком слоте портов.
    Get-WorkflowParallelSettings -Config $config | Out-Null
}

Invoke-GateStep -Name "adapter-paths-exist" -Action {
    $missingAdapters = @(Find-WorkflowMissingAdapterPaths `
        -RepositoryRoot $repositoryRoot `
        -Config $config)
    if ($missingAdapters.Count -gt 0) {
        $details = @($missingAdapters | ForEach-Object { "$($_.Setting)='$($_.Declared)'" })
        throw "Declared project adapter files are missing: $($details -join ', '). Reinstall the workflow kit or add the project implementation."
    }
    Write-Host "    все объявленные адаптеры существуют"
}

# ── 7. Кодировка PowerShell-скриптов ──────────────────────────────────────────
# Windows PowerShell 5.1 декодирует .ps1 БЕЗ BOM в системной ANSI-кодировке.
# UTF-8 кириллица превращается в мусор, а отдельные последовательности — в
# типографские кавычки, которые PowerShell считает открывающими строку: скрипт
# перестаёт разбираться целиком. Дефект зависит от локали машины, поэтому у одного
# разработчика всё работает, а у другого нет. Поэтому BOM обязателен.
Invoke-GateStep -Name "powershell-encoding" -Action {
    $encodingCandidates = @(
        (Invoke-WorkflowGit `
            -RepositoryRoot $repositoryRoot `
            -Arguments @("-c", "core.quotePath=false", "ls-files", "*.ps1", "*.psm1", "*.psd1")).Output |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    $missingBom = @()
    foreach ($relative in $encodingCandidates) {
        $path = Join-Path $repositoryRoot $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            continue
        }
        $bytes = [System.IO.File]::ReadAllBytes($path)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            continue
        }
        # BOM требуется БЕЗУСЛОВНО, а не только для файлов с не-ASCII. Иначе
        # чисто-ASCII скрипт проходит проверку, а ломается в тот момент, когда в
        # него добавят первую строку с кириллицей — уже в другом MR, где причина
        # будет неочевидна.
        $missingBom += $relative
    }
    if ($missingBom.Count -gt 0) {
        throw "$($missingBom.Count) PowerShell script(s) have no UTF-8 BOM, so Windows PowerShell 5.1 will mis-decode any non-ASCII character in them: $(@($missingBom | Select-Object -First 5) -join ', ')"
    }
}

# ── 8. Все PowerShell-скрипты разбираются ─────────────────────────────────────
Invoke-GateStep -Name "powershell-parses" -Action {
    $scriptFiles = @(
        (Invoke-WorkflowGit `
            -RepositoryRoot $repositoryRoot `
            -Arguments @("-c", "core.quotePath=false", "ls-files", "*.ps1")).Output |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    $broken = @()
    foreach ($relative in $scriptFiles) {
        $path = Join-Path $repositoryRoot $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            continue
        }
        $parseErrors = $null
        $tokens = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            [System.IO.Path]::GetFullPath($path),
            [ref]$tokens,
            [ref]$parseErrors
        )
        if ($null -ne $parseErrors -and @($parseErrors).Count -gt 0) {
            $first = @($parseErrors)[0]
            $broken += "${relative}:$($first.Extent.StartLineNumber) $($first.Message)"
        }
    }
    if ($broken.Count -gt 0) {
        throw "PowerShell parse errors: $($broken -join ' | ')"
    }
    Write-Host "    parsed $($scriptFiles.Count) script(s)"
}

Invoke-GateStep -Name "powershell-lint" -Action {
    # Разбор кода эту порчу пропускает: испорченный генерацией путь остаётся
    # синтаксически верной строкой, а падает он в рантайме и в чужом месте.
    $scriptFiles = @(
        (Invoke-WorkflowGit `
            -RepositoryRoot $repositoryRoot `
            -Arguments @("-c", "core.quotePath=false", "ls-files", "*.ps1", "*.psm1")).Output |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    $paths = @($scriptFiles | ForEach-Object { Join-Path $repositoryRoot $_ })
    $issues = @(Find-WorkflowPowerShellLintIssues -Paths $paths)
    if ($issues.Count -eq 0) {
        Write-Host "    подозрительных строковых литералов нет"
        return
    }

    $sample = @(
        $issues | Select-Object -First 5 | ForEach-Object {
            $relative = $_.Path.Substring($repositoryRoot.TrimEnd([char]92).Length + 1)
            "${relative}:$($_.Line) — $($_.Message)"
        }
    )
    throw ("Подозрительные строковые литералы: $($issues.Count). $($sample -join ' | ')")
}

# ── 9. Файлы процесса не правились по месту ───────────────────────────────────
# Правило «изменения процесса вносить в комплект, а не правкой этих файлов по
# месту» существовало, но не проверялось ничем: processVersion был утверждением,
# которое нельзя опровергнуть, и расхождение обнаруживалось случайно и поздно.
#
# Замок пишет установщик и перечисляет только файлы, которые проект менять не
# должен: скрипты фаз, gate, инструменты прогона. Заготовки — манифест проекта,
# политика тестов, CODEOWNERS, документация — в замок не попадают: их правка под
# себя и есть нормальная работа.
#
# Осознанная правка по месту возможна через processDevelopment в .1c-workflow.json.
# Она нужна тем, кто дорабатывает сам процесс: проверить правку, не выполнив её
# там, где есть база и стенды, нельзя. Шаг тогда не пропускается молча, а прямо
# сообщает, что контроль снят.
$lockPath = Join-Path $repositoryRoot ".1c-workflow.lock.json"
if (Test-Path -LiteralPath $lockPath -PathType Leaf) {
    Invoke-GateStep -Name "process-files-unmodified" -Action {
        if ([bool](Get-WorkflowSettingValue -Object $config -Name "processDevelopment" -Default $false)) {
            Write-Host "    processDevelopment = true: сверка файлов процесса ОТКЛЮЧЕНА."
            Write-Host "    Правки по месту допускаются. Перенесите их в комплект и обновите установку."
            return
        }

        $lock = Get-Content -Raw -LiteralPath $lockPath -Encoding UTF8 | ConvertFrom-Json
        $lockedVersion = [string](Get-WorkflowSettingValue -Object $lock -Name "processVersion" -Default "")
        $projectVersion = [string](Get-WorkflowSettingValue -Object $config -Name "processVersion" -Default "")
        if ($lockedVersion -and $projectVersion -and $lockedVersion -ne $projectVersion) {
            throw "Версия процесса в .1c-workflow.json ($projectVersion) не совпадает с замком ($lockedVersion). Переустановите комплект вместо правки поля вручную."
        }

        $files = Get-WorkflowSettingValue -Object $lock -Name "files" -Default $null
        if ($null -eq $files) {
            throw "Замок установки не содержит списка файлов: $lockPath"
        }

        $modified = @()
        $missing = @()
        foreach ($property in @($files.PSObject.Properties)) {
            $relativePath = [string]$property.Name
            $expected = [string]$property.Value
            $fullPath = Join-Path $repositoryRoot ($relativePath -replace '/', '\')
            if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
                $missing += $relativePath
                continue
            }
            if ((Get-WorkflowManagedFileHash -Path $fullPath) -ne $expected) {
                $modified += $relativePath
            }
        }

        if ($missing.Count -gt 0 -or $modified.Count -gt 0) {
            $details = @()
            if ($modified.Count -gt 0) {
                $details += "изменены: $($modified -join ', ')"
            }
            if ($missing.Count -gt 0) {
                $details += "отсутствуют: $($missing -join ', ')"
            }
            throw "Файлы, которыми управляет комплект, отличаются от установленных ($($details -join '; ')). Внесите изменение в onec-ai-dev-flow и переустановите комплект, либо выставьте processDevelopment=true, если дорабатываете сам процесс."
        }
        Write-Host "    проверено файлов: $(@($files.PSObject.Properties).Count), версия процесса $lockedVersion"
    }
}

# ── 7. Целостность выгрузки ───────────────────────────────────────────────────
$integrityLog = Join-Path $logDirectory "source-integrity.log"
$integrityReport = if ($SourceIntegrityReportPath) {
    $SourceIntegrityReportPath
}
else {
    Join-Path $stateDirectory "reports\ci-source-integrity-$timestamp.json"
}
Invoke-GateStep -Name "source-integrity" -LogPath $integrityLog -Action {
    Invoke-WorkflowPowerShell `
        -ScriptPath (Join-Path $workflowDirectory "Test-SourceIntegrity.ps1") `
        -Arguments @("-ReportPath", $integrityReport) `
        -LogPath $integrityLog
}

# ── 8. Политика актуализации тестов ───────────────────────────────────────────
if (-not $SkipTestMaintenance) {
    $maintenanceLog = Join-Path $logDirectory "test-maintenance.log"
    $maintenanceReport = if ($TestMaintenanceReportPath) {
        $TestMaintenanceReportPath
    }
    else {
        Join-Path $stateDirectory "reports\ci-test-maintenance-$timestamp.json"
    }
    Invoke-GateStep -Name "test-maintenance" -LogPath $maintenanceLog -Action {
        $arguments = @("-ReportPath", $maintenanceReport)
        if ($BaseRef) {
            $arguments += @("-BaseRef", $BaseRef)
        }
        Invoke-WorkflowPowerShell `
            -ScriptPath (Join-Path $workflowDirectory "Test-TestMaintenance.ps1") `
            -Arguments $arguments `
            -LogPath $maintenanceLog
    }
}

Invoke-GateStep -Name "pending-scenarios" -Action {
    # Отложенные сценарии — единственное разрешённое «пока не проверяем». Механизм
    # удобный, и потому опасный: без учёта он превращается в свалку, а через
    # полгода никто не решится удалить файл, про который неизвестно, чей он.
    #
    # Здесь проверяется ФОРМА шапки и печатается возраст. Возраст сам по себе
    # отказом не является: задача может идти месяцами, и рушить чужие MR из-за
    # чужого долга — верный способ добиться того, чтобы механизм обходили.
    $pending = @(Get-WorkflowPendingScenarios -RepositoryRoot $repositoryRoot -Config $config)
    if ($pending.Count -eq 0) {
        Write-Host "    отложенных сценариев нет"
        return
    }
    $broken = @($pending | Where-Object { [string]$_.Problem })
    if ($broken.Count -gt 0) {
        $lines = @($broken | ForEach-Object { "$($_.Path) — $($_.Problem)" })
        throw "Отложенные сценарии оформлены неверно ($($broken.Count)). Нужна шапка export const pending = { task, since, reason }:`n  $($lines -join "`n  ")"
    }
    Write-Host "    отложенных сценариев: $($pending.Count)"
    foreach ($entry in @($pending | Sort-Object -Property @{ Expression = { $_.AgeDays }; Descending = $true })) {
        Write-Host "      $($entry.Path) — $($entry.Task), $($entry.AgeDays) дн.: $($entry.Reason)"
    }
}

$success = $failures.Count -eq 0
$report = [pscustomobject]@{
    operation = "ci-gate"
    project = [string]$config.project
    # Версия процесса, на которой работает проект: без неё невозможно понять,
    # какие правила действовали в момент проверки, и раскатывать обновления
    # комплекта на несколько конфигураций.
    processVersion = [string](Get-WorkflowSettingValue -Object $config -Name "processVersion" -Default "unknown")
    branch = Get-WorkflowStandBranchName -RepositoryRoot $repositoryRoot
    commit = Get-WorkflowHeadCommit -RepositoryRoot $repositoryRoot
    success = $success
    platformChecked = $false
    pendingScenarios = @(
        Get-WorkflowPendingScenarios -RepositoryRoot $repositoryRoot -Config $config |
            ForEach-Object {
                [pscustomobject]@{
                    path = $_.Path
                    task = $_.Task
                    since = $_.Since
                    reason = $_.Reason
                    ageDays = $_.AgeDays
                    problem = $_.Problem
                }
            }
    )
    steps = @($steps)
    failures = @($failures)
    completedAt = [DateTimeOffset]::Now.ToString("o")
}
Write-WorkflowJson -Value $report -Path $ReportPath | Out-Null

Write-Host ""
Write-Host "CI gate report: $ReportPath"
Write-Host "NOTE: this gate does not compile the configuration. Local phases Compile/Selfcheck/Verify remain mandatory."
if (-not $success) {
    throw "CI gate failed: $($failures -join ' | ')"
}
Write-Host "CI gate passed."
