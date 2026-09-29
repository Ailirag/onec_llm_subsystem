[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet(
        "Start", "Probe", "Design", "Compile", "Selfcheck", "Critique", "Verify", "Package", "Release", "Status",
        # Подъём комплекта процесса: ветка, в которой изменены только его файлы.
        "KitUpdate",
        # Устаревшие имена, принимаются с предупреждением.
        "Check", "Finish", "Review"
    )]
    [string]$Phase,

    [string]$BasePath = "",

    # Корень, в котором ЭТА машина держит базы разработки и стенды. Спрашивается
    # один раз при подготовке рабочего места, дальше живёт в профиле пользователя.
    [string]$BaseRoot = "",

    # Фаза Critique: с чем сравнивать правку. Пусто — origin/<основная>.
    [string]$BaseRef = "",

    # Фаза Critique: собрать пакет и не запускать ревьюера.
    [switch]$PacketOnly,

    # Фаза Critique: отклонить замечание с причиной, "<ключ>=<причина>".
    [string]$Dismiss = "",

    # Имя или псевдоним базы из .v8-project.json. Нужен там, где на человека
    # заведено несколько баз и ветка сама по себе не выбирает нужную.
    [string]$Database = "",

    [string]$V8Path = "",
    [string]$BspSourcePath = "",
    [string]$ReleaseOutputPath = "",

    # Перезалить базу исходниками из рабочей копии. Для файловой базы это
    # пересоздание, для серверной — повторная загрузка: серверную базу комплект
    # не удаляет.
    [switch]$Reload,
    # Прежнее имя ключа, синоним -Reload.
    [switch]$Recreate,
    [switch]$CompileOnly,
    [switch]$IncludeHttp,
    [switch]$IncludeWebUi,
    [switch]$Stage,
    # Собрать cf, проверив только затронутое правкой, без полного регресса.
    # Результат не является выпуском: в Git не кладётся и называется иначе.
    [switch]$AffectedOnly,
    [switch]$Force,
    [switch]$AllowMainStart,
    [switch]$ForceAgentConfig,
    [switch]$AdoptResources,

    # Отбор для фазы Probe. Пути указываются внутри сьюта Web UI; без них и без
    # -FunctionalTest цели выводятся из diff. Теги и -Grep сужают отобранное дальше.
    [string[]]$TestPath = @(),

    # Имена тестов функционального контура для фазы Probe. Передаются адаптеру
    # functionalTests.smokeScript ключом -Tests; фаза сверяет, что названные
    # тесты действительно выполнились.
    [string[]]$FunctionalTest = @(),

    [string[]]$Tags = @(),
    [string]$Grep = "",
    [switch]$Bail,

    # Фаза Status: картина внедрения процесса вместо состояния задачи.
    [switch]$Adoption,

    # Фаза Verify: понизить маршрут с причиной. Правило, из которого нет выхода,
    # обходят молча; выход есть, он записан и виден на ревью.
    [string]$RouteDowngrade = "",

    # Фаза Design: что предстоит сделать. Правки ещё нет, и вывести задачу из
    # кода невозможно — в этом и смысл этапа.
    [string]$Task = "",

    # Поднимает объём Web UI прогона до полного на любой фазе. По умолчанию объём
    # берётся из webUiTests.scope манифеста и полным не является нигде, кроме
    # Release — там он полный всегда и отключить его нельзя.
    [switch]$Full
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Workflow.Common.ps1")

# Фазы переименованы, потому что прежние имена не соответствовали смыслу:
#   Check  → Compile   — компиляция и статика, интерфейс не запускается;
#   Finish → Selfcheck — самопроверка рабочей копии автора;
#   Review → Verify    — верификация коммита, который уходит в MR.
# «Review» вводил в заблуждение сильнее всего: это не человеческое ревью, а
# проверка перед ним, и порядок «Finish, затем Review» читался как ошибка.
$phaseAliases = @{
    "Check" = "Compile"
    "Finish" = "Selfcheck"
    "Review" = "Verify"
}
if ($phaseAliases.ContainsKey($Phase)) {
    $modernPhase = $phaseAliases[$Phase]
    Write-Warning "Фаза '$Phase' переименована в '$modernPhase'. Старое имя пока принимается; используйте -Phase $modernPhase."
    $Phase = $modernPhase
}

function Test-ConfigFlag {
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

function Invoke-WorkflowPhaseScript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$ScriptName,

        [string[]]$Arguments = @()
    )

    # Путь нормализуется: фазы вызывают не только скрипты из scripts\workflow, но и
    # серверный gate из scripts\ci, и без нормализации в сообщениях об ошибках
    # появляется нечитаемое "scripts\workflow\..\ci\Invoke-Gate.ps1".
    $scriptPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot $ScriptName))
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw "Workflow phase '$Name' requires a missing script: $scriptPath"
    }
    $timestamp = "$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')-$PID"
    $logPath = Join-Path $script:logDirectory "$($Phase.ToLowerInvariant())-$Name-$timestamp.log"
    $result = Invoke-WorkflowPowerShell `
        -ScriptPath $scriptPath `
        -Arguments $Arguments `
        -LogPath $logPath
    foreach ($line in @($result.Output)) {
        Write-Host $line
    }
    return $result
}

function Assert-TaskState {
    param(
        [AllowNull()]
        [object]$State,

        [Parameter(Mandatory = $true)]
        [string[]]$AllowedPhases,

        [Parameter(Mandatory = $true)]
        [string]$CurrentBranch
    )

    # Отказ называет ПОСЛЕДОВАТЕЛЬНОСТЬ для запрошенной фазы, а не только
    # несоответствие. Читающий отказ хочет знать, что набрать дальше; «Run Start»
    # без второй команды заставляет вспоминать, чего он вообще добивался — а при
    # подъёме комплекта это ещё и неочевидно: фаза лёгкая, но базу для компиляции
    # ей всё равно готовит Start.
    $sequence = "Invoke-TaskWorkflow.ps1 -Phase Start, then -Phase $Phase"

    if ($null -eq $State) {
        throw "Task workflow is not initialized. Run $sequence."
    }
    if ([string]$State.branch -ne $CurrentBranch) {
        throw ("Task state belongs to branch '$($State.branch)', current branch is " +
            "'$CurrentBranch'. Run $sequence.")
    }
    if (@($AllowedPhases) -notcontains [string]$State.phase) {
        throw "Phase '$($State.phase)' cannot transition to '$Phase'. Expected: $($AllowedPhases -join ', ')."
    }
}

function Get-PreflightOutcome {
    <#
    .SYNOPSIS
    Читает из отчёта preflight, был ли он полным и признан ли релизопригодным.

    .DESCRIPTION
    Без этого «checked» невозможно отличить от «проверено только компиляцией»:
    состояние задачи выглядело одинаково и в том случае, когда UpdateDBCfg
    выполнялся, и когда был пропущен.
    #>
    param(
        [string]$ReportPath = ""
    )

    $outcome = [pscustomobject]@{
        compileOnly = $null
        releaseReady = $null
        webUiScope = $null
    }
    if (-not $ReportPath -or -not (Test-Path -LiteralPath $ReportPath -PathType Leaf)) {
        return $outcome
    }
    try {
        $report = Get-Content -Raw -LiteralPath $ReportPath -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        return $outcome
    }
    if ($null -ne $report.PSObject.Properties["compileOnly"]) {
        $outcome.compileOnly = [bool]$report.compileOnly
    }
    if ($null -ne $report.PSObject.Properties["releaseReady"]) {
        $outcome.releaseReady = [bool]$report.releaseReady
    }
    if ($null -ne $report.PSObject.Properties["webUiScope"]) {
        $outcome.webUiScope = [string]$report.webUiScope
    }
    return $outcome
}

function Get-PlatformImpact {
    <#
    .SYNOPSIS
    Считает, нужна ли этой ветке проверка платформой, и говорит об этом вслух.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$PhaseName
    )

    $impact = Get-WorkflowPlatformImpact `
        -RepositoryRoot $script:repositoryRoot `
        -BaseRef "origin/$([string]$script:config.mainBranch)"
    if ($impact.Impacts) {
        return $impact
    }

    Write-Host ""
    Write-Host "${PhaseName}: ветка не меняет ничего, что проверяет платформа."
    Write-Host "Изменено относительно $($impact.BaseRef) и в рабочем дереве:"
    foreach ($path in @($impact.Paths)) {
        Write-Host "  $path"
    }
    Write-Host "Конфигурация и тесты совпадают с основной веткой, поэтому сборка базы"
    Write-Host "дала бы тот же ответ, что уже получен на ней. Проверки, не требующие"
    Write-Host "платформы, выполняет gate — он запускается как обычно."
    Write-Host ""
    return $impact
}

function Write-SkippedPreflightReport {
    <#
    .SYNOPSIS
    Пишет отчёт фазы, пропустившей проверку платформой.

    .DESCRIPTION
    Отчёт обязателен. Без него состояние задачи выглядело бы как после обычной
    фазы, и «проверено платформой» стало бы неотличимо от «платформа не
    запускалась». Поэтому признак `skipped`, база сравнения и фактический объём
    пишутся явно, а `releaseReady` остаётся ложным.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [object]$Impact
    )

    $report = [pscustomobject]@{
        operation = "preflight"
        project = [string]$script:config.project
        branch = $script:branchName
        commit = $script:headCommit
        success = $true
        skipped = $true
        skipReason = "no-platform-impact"
        skipBaseRef = [string]$Impact.BaseRef
        changedPaths = @($Impact.Paths)
        releaseReady = $false
        compileOnly = $false
        webUiIncluded = $false
        webUiScope = "none"
        httpIncluded = $false
        steps = @()
        completedAt = [DateTimeOffset]::Now.ToString("o")
    }
    Write-WorkflowJson -Value $report -Path $Path | Out-Null
    Write-Host "Preflight report: $Path"
}

function Get-ReuseDenial {
    param([string]$Reason)

    Write-Host "Verify выполняет проверку платформой заново: $Reason."
    return $null
}

function Get-ReusableSelfcheckReport {
    <#
    .SYNOPSIS
    Отчёт Selfcheck, если он доказывает ровно тот коммит и объём, которых требует
    Verify. Иначе $null.

    .DESCRIPTION
    Verify повторяла Selfcheck целиком: обе фазы читают одни и те же файлы и
    выполняют одинаковый список шагов. Отличий два — gate и требование чистого
    дерева, — и ни одно из них не меняет результата платформенной части. На
    замеренной итерации это 189 секунд из 420, выведенных повторно.

    Привязка идёт к ОТПЕЧАТКУ, а не к состоянию «Selfcheck был зелёный». Разница
    принципиальна: состояние говорит «когда-то прошло», отпечаток — «прошло РОВНО
    ЭТО». Привязка к состоянию рано или поздно позволила бы верифицировать коммит,
    которого Selfcheck не видел, и по составу отчёта это выглядело бы неотличимо от
    честной проверки — тот же класс дефекта, против которого введён `releaseReady`.

    Каждое условие ниже закрывает случай, где Selfcheck доказал МЕНЬШЕ, чем требует
    Verify. Отказ печатается с причиной: молчаливый отказ читался бы как «эта
    оптимизация не работает».
    #>
    param(
        [AllowNull()]
        [object]$TaskState,

        [Parameter(Mandatory = $true)]
        [string]$RequiredWebUiScope,

        [Parameter(Mandatory = $true)]
        [bool]$RequiresWebUi,

        [Parameter(Mandatory = $true)]
        [bool]$RequiresHttp
    )

    if ($null -eq $TaskState) {
        return Get-ReuseDenial "локального состояния задачи нет"
    }
    if ([string]$TaskState.branch -ne $script:branchName) {
        return Get-ReuseDenial "состояние принадлежит ветке '$($TaskState.branch)'"
    }
    if ([string]$TaskState.phase -ne "selfcheck-passed") {
        return Get-ReuseDenial "последняя фаза — '$($TaskState.phase)', а не Selfcheck"
    }
    # Сравнения НОМЕРА коммита здесь намеренно нет, хотя оно напрашивается.
    # Selfcheck идёт по рабочему дереву, до коммита; коммит делается сразу после
    # него и ровно из того, что он проверил. Сравнение SHA отсекало именно этот —
    # нормальный — ход работы и заставляло повторять полный прогон над теми же
    # файлами. Отвечать за коммит оно тоже не помогает: содержимое коммита
    # определяют отпечаток и чистота дерева, а не его номер.
    $currentFingerprint = Get-WorkflowFingerprint -RepositoryRoot $script:repositoryRoot
    if ([string]$TaskState.fingerprint -ne $currentFingerprint) {
        return Get-ReuseDenial "файлы изменились после Selfcheck"
    }

    # Отпечаток совпал бы и на грязном дереве, если Selfcheck шёл на том же грязном
    # дереве. Verify обязана отвечать за коммит, а не за рабочую копию, поэтому
    # чистоту требуем отдельно, а не выводим из отпечатка. Вместе эти два условия
    # и означают «содержимое коммита — то самое»: чистое дерево равно HEAD, а
    # отпечаток равен проверенному.
    $status = @(
        (Invoke-WorkflowGit `
            -RepositoryRoot $script:repositoryRoot `
            -Arguments @("status", "--porcelain")).Output
    )
    if ($status.Count -gt 0) {
        return Get-ReuseDenial "рабочее дерево не чистое"
    }

    $reportPath = [string]$TaskState.report
    if (-not $reportPath -or -not (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
        return Get-ReuseDenial "отчёт Selfcheck не найден"
    }
    try {
        $report = Get-Content -Raw -LiteralPath $reportPath -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        return Get-ReuseDenial "отчёт Selfcheck нечитаем"
    }
    if ($null -ne $report.PSObject.Properties["probe"] -and [bool]$report.probe) {
        return Get-ReuseDenial "это отчёт петли Probe, а не Selfcheck"
    }
    if (-not [bool]$report.success) {
        return Get-ReuseDenial "Selfcheck завершился неуспешно"
    }
    if ([bool]$report.compileOnly) {
        return Get-ReuseDenial "Selfcheck выполнялся без UpdateDBCfg"
    }
    if ($null -ne $report.PSObject.Properties["skipped"] -and [bool]$report.skipped) {
        return Get-ReuseDenial "Selfcheck сам пропустил проверку платформой"
    }
    if ($RequiresWebUi) {
        if (-not [bool]$report.webUiIncluded) {
            return Get-ReuseDenial "Selfcheck не выполнял Web UI"
        }
        if ([string]$report.webUiScope -ne $RequiredWebUiScope) {
            return Get-ReuseDenial "объём Web UI другой: у Selfcheck '$([string]$report.webUiScope)', требуется '$RequiredWebUiScope'"
        }
    }
    if ($RequiresHttp -and -not [bool]$report.httpIncluded) {
        return Get-ReuseDenial "Selfcheck не выполнял HTTP-проверки"
    }

    return [pscustomobject]@{
        Report = $report
        Path = $reportPath
        Fingerprint = $currentFingerprint
    }
}

function Save-TaskState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$NewPhase,

        [string]$Fingerprint = "",
        [string]$ReportPath = ""
    )

    $previous = Read-WorkflowTaskState -RepositoryRoot $script:repositoryRoot -Config $script:config
    $history = @()
    if ($null -ne $previous -and $null -ne $previous.history) {
        $history += @($previous.history)
    }
    $history += [pscustomobject]@{
        phase = $NewPhase
        branch = $script:branchName
        commit = $script:headCommit
        fingerprint = $Fingerprint
        report = $ReportPath
        completedAt = [DateTimeOffset]::Now.ToString("o")
    }

    $databaseState = Read-WorkflowState -RepositoryRoot $script:repositoryRoot -Config $script:config
    $outcome = Get-PreflightOutcome -ReportPath $ReportPath
    $state = [pscustomobject]@{
        schemaVersion = 1
        project = [string]$script:config.project
        branch = $script:branchName
        phase = $NewPhase
        commit = $script:headCommit
        fingerprint = $Fingerprint
        basePath = if ($null -ne $databaseState) { [string]$databaseState.basePath } else { "" }
        report = $ReportPath
        # Явно фиксируем полноту проверки: фаза сама по себе не отвечает на
        # вопрос «выполнялся ли UpdateDBCfg».
        compileOnly = $outcome.compileOnly
        releaseReady = $outcome.releaseReady
        # Фактический объём Web UI прогона. Без него «фаза пройдена» не отличается
        # от «пройдено то, что выбрали»: состояние выглядит одинаково.
        webUiScope = $outcome.webUiScope
        history = $history
        updatedAt = [DateTimeOffset]::Now.ToString("o")
    }
    $path = Write-WorkflowTaskState `
        -RepositoryRoot $script:repositoryRoot `
        -Config $script:config `
        -State $state
    Write-Host "Task workflow state: $path"
    return $state
}

$repositoryRoot = Get-WorkflowRepositoryRoot -StartPath $PSScriptRoot
$config = Get-WorkflowConfig -RepositoryRoot $repositoryRoot
$branchName = Get-WorkflowBranchName -RepositoryRoot $repositoryRoot
if (-not $branchName) {
    throw "Task workflow requires a named Git branch."
}
$headCommit = [string](
    (Invoke-WorkflowGit -RepositoryRoot $repositoryRoot -Arguments @("rev-parse", "HEAD")).Output |
        Select-Object -First 1
)
$stateDirectory = Resolve-WorkflowPath -RepositoryRoot $repositoryRoot -Path ([string]$config.localStateDir)
$logDirectory = Join-Path $stateDirectory "logs\task-workflow"
[System.IO.Directory]::CreateDirectory($logDirectory) | Out-Null
$taskState = Read-WorkflowTaskState -RepositoryRoot $repositoryRoot -Config $config

if ($Phase -eq "Status" -and $Adoption) {
    # Отчёт, а не проверка: внедрение постепенное по построению, и отказ на
    # неполном внедрении ронял бы gate у всех, кто идёт этим путём честно.
    # Имя нарочно отличается от ключа -Adoption не только регистром: PowerShell
    # регистр не различает, и объект, присвоенный $adoption, летел в [switch].
    $adoptionStatus = Get-WorkflowAdoptionStatus `
        -RepositoryRoot $repositoryRoot `
        -Config $config `
        -TaskState $taskState

    Write-Host ""
    Write-Host "Внедрение процесса: выполнено $($adoptionStatus.Done) из $($adoptionStatus.Total)"
    Write-Host ""
    foreach ($item in @($adoptionStatus.Items)) {
        Write-Host ("  {0,-8} {1,-34} {2}" -f $item.State, $item.Name, $item.Detail)
    }
    Write-Host ""
    if ($adoptionStatus.CyclePassed) {
        Write-Host "Задача проходила цикл целиком — процесс работает, а не просто установлен."
    }
    else {
        Write-Host "Ни одна задача не доведена до Verify: процесс установлен, но не внедрён."
    }
    $routeNow = Get-WorkflowChangeRoute `
        -Config $config `
        -ChangedPaths (Get-WorkflowChangedPaths -RepositoryRoot $repositoryRoot -BaseRef "origin/$([string]$config.mainBranch)") `
        -AddedPaths (Get-WorkflowAddedPaths -RepositoryRoot $repositoryRoot -BaseRef "origin/$([string]$config.mainBranch)")
    Write-Host ""
    Write-Host "Маршрут текущей правки: $($routeNow.Route)"
    foreach ($reason in @($routeNow.Reasons)) {
        Write-Host "  $reason"
    }

    Write-Host ""
    Write-Host "Отчёт показывает состояние, а не качество: включённый набор проверок"
    Write-Host "может быть пустым, а пройденная фаза подтверждать меньше, чем кажется."
    return
}

if ($Phase -eq "Status") {
    $currentFingerprint = Get-WorkflowFingerprint -RepositoryRoot $repositoryRoot
    $status = [pscustomobject]@{
        project = [string]$config.project
        branch = $branchName
        commit = $headCommit
        phase = if ($null -ne $taskState) { [string]$taskState.phase } else { "not-started" }
        storedFingerprint = if ($null -ne $taskState) { [string]$taskState.fingerprint } else { "" }
        currentFingerprint = $currentFingerprint
        stale = [bool](
            $null -ne $taskState -and
            [string]$taskState.fingerprint -and
            [string]$taskState.fingerprint -ne $currentFingerprint
        )
        basePath = if ($null -ne $taskState) { [string]$taskState.basePath } else { "" }
        compileOnly = if ($null -ne $taskState -and $null -ne $taskState.PSObject.Properties["compileOnly"]) {
            $taskState.compileOnly
        }
        else {
            $null
        }
        releaseReady = if ($null -ne $taskState -and $null -ne $taskState.PSObject.Properties["releaseReady"]) {
            $taskState.releaseReady
        }
        else {
            $null
        }
        statePath = Get-WorkflowTaskStatePath -RepositoryRoot $repositoryRoot -Config $config
    }
    $status | ConvertTo-Json -Depth 10
    return
}

# .env читается ДО всего остального: из него берутся секреты, которые нужны уже
# на подключении к базе. Имена загруженных переменных печатаются, значения — нет.
$loadedSecrets = @(Import-WorkflowDotEnv -RepositoryRoot $repositoryRoot)
if ($loadedSecrets.Count -gt 0) {
    Write-Host "Из .env взяты переменные: $($loadedSecrets -join ', ')"
}

# Предупреждение печатается до выбора фазы: коммит на смерженную ветку одинаково
# бесполезен и перед Compile, и перед Verify, а заметен он только здесь. Фаза при
# этом не падает — дерево корректное, не едет результат.
if (Test-WorkflowBranchAlreadyMerged `
    -RepositoryRoot $repositoryRoot `
    -BranchName $branchName `
    -MainBranch ([string]$config.mainBranch)) {
    Write-Host ""
    Write-Warning ("Ветка '$branchName' уже целиком в origin/$([string]$config.mainBranch): " +
        "её MR смержен. Новые коммиты здесь останутся на машине — MR этой ветки закрыт, " +
        "а пуш в неё ничего не откроет.")
    Write-Warning ("Начать следующую задачу так: git checkout $([string]$config.mainBranch); " +
        "git pull; git checkout -b <новая ветка>.")
    Write-Host ""
}

switch ($Phase) {
    "Start" {
        if ($branchName -eq [string]$config.mainBranch -and -not $AllowMainStart) {
            throw "Development must start on a task branch, not '$branchName'. Use -AllowMainStart only for an intentional exception."
        }

        # Круги ревью считаются по задаче, и новая задача начинает счёт заново.
        # Иначе предел, выбранный прошлой задачей, молча запрещал бы ревью этой.
        Reset-WorkflowCritiqueRounds -StateDirectory (
            Resolve-WorkflowPath -RepositoryRoot $repositoryRoot -Path ([string]$config.localStateDir)
        )

        # Вопрос задаётся ЗДЕСЬ, а не внутри Initialize-Developer: фаза запускает
        # скрипт дочерним процессом с перехватом вывода, и приглашение Read-Host
        # ушло бы в лог, а не на экран — человек увидел бы молчащую фазу.
        $machineRoots = Resolve-WorkflowBaseRoots -Config $config -Explicit $BaseRoot
        if ($BaseRoot) {
            $baseRootProblem = Test-WorkflowBaseRootProblem `
                -RepositoryRoot $repositoryRoot -BaseRoot $BaseRoot
            if ($baseRootProblem) {
                throw "Ключ -BaseRoot не годится: $baseRootProblem"
            }
            $savedPath = Save-WorkflowMachineBaseRoot -Config $config -BaseRoot $BaseRoot
            Write-Host "Корень баз этой машины записан: $([System.IO.Path]::GetFullPath($BaseRoot)) ($savedPath)"
        }
        elseif (-not $machineRoots.DevRoot) {
            if (-not (Test-WorkflowInteractiveHost)) {
                Assert-WorkflowBaseRoot -Root ""
            }
            $answer = Request-WorkflowBaseRoot -RepositoryRoot $repositoryRoot -Config $config
            $savedPath = Save-WorkflowMachineBaseRoot -Config $config -BaseRoot $answer
            Write-Host "Корень баз этой машины записан: $answer ($savedPath)"
        }

        $arguments = @()
        if ($BasePath) {
            $arguments += @("-BasePath", $BasePath)
        }
        if ($Database) {
            $arguments += @("-Database", $Database)
        }
        if ($V8Path) {
            $arguments += @("-V8Path", $V8Path)
        }
        if ($BspSourcePath) {
            $arguments += @("-BspSourcePath", $BspSourcePath)
        }
        if ($Reload -or $Recreate) {
            $arguments += "-Reload"
        }
        if ($CompileOnly) {
            $arguments += "-CompileOnly"
        }
        if ($ForceAgentConfig) {
            $arguments += "-ForceAgentConfig"
        }
        if ($AdoptResources) {
            $arguments += "-AdoptResources"
        }
        Invoke-WorkflowPhaseScript `
            -Name "initialize" `
            -ScriptName "Initialize-Developer.ps1" `
            -Arguments $arguments | Out-Null
        Save-TaskState -NewPhase "ready" -Fingerprint (Get-WorkflowFingerprint -RepositoryRoot $repositoryRoot) | Out-Null
    }

    "Design" {
        <#
        Замысел правки до кода. Ревью отвечает «правильно ли это написано» и
        приходит, когда код уже есть; здесь решается, нужно ли делать и где
        этому место. После написания кода этот вопрос стоит переделки.

        Фаза не обязательна к запуску: обязателен её результат. Verify требует
        записанный замысел на сложном маршруте, и способ его получить — любой.
        #>
        $arguments = @()
        if ($Task) {
            $arguments += @("-Task", $Task)
        }
        if ($PacketOnly) {
            $arguments += "-PacketOnly"
        }
        if ($Force) {
            $arguments += "-Force"
        }
        Invoke-WorkflowPhaseScript `
            -Name "design" `
            -ScriptName "Invoke-ArchitectureDesign.ps1" `
            -Arguments $arguments | Out-Null
    }

    "Critique" {
        <#
        Независимое ревью правки. Отдельная фаза, а не шаг Verify: ревью полезно
        звать и раньше, когда решение ещё можно поменять дёшево.

        Пропустить фазу нечем: Verify требует отчёт под нынешний отпечаток и
        падает, если его нет. Работа здесь, проверка там.
        #>
        $arguments = @()
        if ($BaseRef) {
            $arguments += @("-BaseRef", $BaseRef)
        }
        if ($PacketOnly) {
            $arguments += "-PacketOnly"
        }
        if ($Dismiss) {
            $arguments += @("-Dismiss", $Dismiss)
        }
        Invoke-WorkflowPhaseScript `
            -Name "critique" `
            -ScriptName "Invoke-CodeCritique.ps1" `
            -Arguments $arguments | Out-Null
    }

    "Probe" {
        <#
        Петля разработчика. Отвечает на вопрос «работает ли то, что я сейчас пишу»,
        и НЕ отвечает ни на один вопрос обязательных фаз.

        Поэтому Probe:
          - не двигает состояние задачи и не пишет отпечаток. Иначе петля стала бы
            способом получить `selfcheck-passed`, ничего не проверив: по составу
            состояния это выглядело бы неотличимо от честной фазы;
          - не запускает gate, дым, функциональный контур и Test-Configuration:
            временная база с нуля — это и есть те минуты, ради которых петля
            заводится;
          - грузит правки В ТОТ стенд, на котором потом прогоняет. Прогон по
            стенду, куда правка не доехала, зелёный и бессмысленный — это худший
            из возможных исходов, потому что он выглядит как успех.

        Стенд Probe не создаёт: сборка стенда со сдачей данных — работа Selfcheck.
        Нет стенда — отказ с указанием, что запустить.
        #>
        if ($null -eq $taskState) {
            throw "Probe works on an initialized workspace. Run Invoke-TaskWorkflow.ps1 -Phase Start first."
        }
        if ([string]$taskState.branch -ne $branchName) {
            throw "Task state belongs to branch '$($taskState.branch)', current branch is '$branchName'. Run Start for this branch."
        }

        $webUiConfig = Get-WorkflowSettingValue -Object $config -Name "webUiTests" -Default $null
        $functionalConfig = Get-WorkflowSettingValue -Object $config -Name "functionalTests" -Default $null
        $standBranch = Get-WorkflowStandBranchName -RepositoryRoot $repositoryRoot
        $timestamp = "$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')-$PID"
        $probeReportPath = Join-Path $stateDirectory "reports\probe-$timestamp.json"

        # Цели Web UI выводятся из diff только тогда, когда человек ничего не назвал.
        # Разбор diff стоит запуска политики, и делать его ради вызова с -TestPath
        # или -FunctionalTest незачем.
        $affectedTargets = @()
        if ($TestPath.Count -eq 0 -and $FunctionalTest.Count -eq 0) {
            if ($null -eq $webUiConfig -or -not [bool]$webUiConfig.enabled) {
                throw (
                    "Probe derives its targets from the Web UI suite, but webUiTests.enabled is false. " +
                    "Name what to run with -TestPath or -FunctionalTest."
                )
            }
            $affected = Get-WorkflowAffectedSuiteTargets `
                -RepositoryRoot $repositoryRoot `
                -Config $config `
                -BaseRef "origin/$([string]$config.mainBranch)"
            if ($affected.WholeSuite) {
                throw (
                    "The change widened the selection to the whole suite (rules: " +
                    "$(@($affected.WholeSuiteRules) -join ', ')). Probe is a development loop, " +
                    "not a regression run: name the scenarios with -TestPath, or run " +
                    "Invoke-TaskWorkflow.ps1 -Phase Selfcheck."
                )
            }
            $affectedTargets = @($affected.Targets)
            if (@($affected.OutsideSuite).Count -gt 0) {
                Write-Host "Затронуто вне сьюта Web UI: $(@($affected.OutsideSuite) -join ', ')"
                Write-Host "  Функциональные тесты по diff не выводятся — назови их ключом -FunctionalTest."
            }
        }

        $probePlan = Get-WorkflowProbePlan `
            -TestPath $TestPath `
            -FunctionalTest $FunctionalTest `
            -AffectedTargets $affectedTargets

        if ($probePlan.RunWebUi -and @($probePlan.WebUiTargets).Count -eq 0) {
            $probePlan.RunWebUi = $false
        }
        if (-not $probePlan.RunFunctional -and -not $probePlan.RunWebUi) {
            Write-Host "Probe: прогонять нечего — правки не задевают ни одного сценария сьюта."
            Write-Host "Назови сценарий ключом -TestPath или тест ключом -FunctionalTest."
            return
        }

        # Что именно поедет, печатается ДО проверок стенда: если стенда нет,
        # разработчику всё равно полезно видеть выбранное.
        if ($probePlan.RunFunctional) {
            Write-Host "Probe functional: $(@($probePlan.FunctionalTests) -join ', ')"
        }
        if ($probePlan.RunWebUi) {
            Write-Host "Probe web ui ($($probePlan.WebUiSelection)): $(@($probePlan.WebUiTargets) -join ', ')"
        }

        function Resolve-ProbeStand {
            param([string]$Kind, [string]$Description, [string]$HowToBuild)

            $path = Get-WorkflowStandBasePath -Config $config -BranchName $standBranch -Kind $Kind
            $infoBase = if ($Database) {
                Resolve-WorkflowInfoBase `
                    -RepositoryRoot $repositoryRoot `
                    -Config $config `
                    -BranchName $branchName `
                    -Database $Database
            }
            else {
                ConvertTo-WorkflowInfoBase -BasePath $path -Caller "Probe"
            }
            if (
                [string]$infoBase.Kind -ne "server" -and
                -not (Test-Path -LiteralPath (Join-Path ([string]$infoBase.Path) "1Cv8.1CD") -PathType Leaf)
            ) {
                throw (
                    "The $Description does not exist yet: $($infoBase.Display). Probe never builds a stand: " +
                    "building it and seeding its data takes minutes, and that is exactly what the loop exists to avoid. " +
                    "Build it once with $HowToBuild, then re-run Probe. " +
                    "Note that the mandatory phases will NOT do it for you: they build a throwaway stand under the " +
                    "temporary preflight directory and delete it afterwards."
                )
            }
            return $infoBase
        }

        function Invoke-ProbeApply {
            param([object]$InfoBase, [string]$Name)

            # Правки грузятся В ТОТ стенд, на котором пойдёт прогон. Зелёный прогон
            # по стенду, куда правка не доехала, — худший из исходов: он выглядит
            # как успех. Загрузка инкрементальная, точка отсчёта у каждой базы своя.
            $arguments = if ($Database) {
                @("-Database", $Database)
            }
            else {
                @("-BasePath", ([string]$InfoBase.Path))
            }
            if ($V8Path) {
                $arguments += @("-V8Path", $V8Path)
            }
            Invoke-WorkflowPhaseScript `
                -Name $Name `
                -ScriptName "Apply-GitChanges.ps1" `
                -Arguments $arguments | Out-Null
        }

        $probeFailure = $null
        $functionalStand = ""
        $webUiStand = ""
        $webUiReportPath = ""
        $functionalResultPath = ""

        # Функциональный контур идёт первым: он дешевле, и его отказ делает
        # проверку интерфейса бессмысленной.
        if ($probePlan.RunFunctional -and $null -eq $probeFailure) {
            # Куда идёт отбор, решает манифест. Настроен контур модульных тестов —
            # идём в него: он на порядок дешевле и именно в нём пишутся новые
            # проверки прикладной логики. Нет его — прежний путь через дымовой
            # адаптер, чтобы проекты без движка продолжали работать.
            $unitTestsConfig = Get-WorkflowSettingValue -Object $config -Name "unitTests" -Default $null
            $useUnitTests = Test-ConfigFlag -Object $unitTestsConfig -Name "enabled"
            if ($useUnitTests) {
                $probeRunnerRelative = [string](Get-WorkflowSettingValue -Object $unitTestsConfig -Name "script" -Default "")
                if (-not $probeRunnerRelative) {
                    throw "unitTests.enabled is true, but unitTests.script is not set."
                }
            }
            else {
                if ($null -eq $functionalConfig -or -not [bool]$functionalConfig.enabled) {
                    throw "-FunctionalTest was given, but neither unitTests.enabled nor functionalTests.enabled is set."
                }
                $probeRunnerRelative = [string](Get-WorkflowSettingValue -Object $functionalConfig -Name "smokeScript" -Default "")
                if (-not $probeRunnerRelative) {
                    throw "functionalTests.smokeScript is not configured, so named functional tests cannot be run."
                }
            }
            $initializeScript = [string](Get-WorkflowSettingValue -Object $functionalConfig -Name "initializeScript" -Default "")
            $functionalInfoBase = Resolve-ProbeStand `
                -Kind "functional" `
                -Description "functional stand" `
                -HowToBuild $(if ($initializeScript) { $initializeScript } else { "functionalTests.initializeScript" })
            $functionalStand = [string]$functionalInfoBase.Display
            Write-Host "Probe functional stand: $functionalStand"
            Invoke-ProbeApply -InfoBase $functionalInfoBase -Name "probe-apply-functional"

            # Договор адаптера знает только -BasePath. У серверной базы он пуст, и
            # молча передать пустую строку нельзя: адаптер вывел бы файловый путь
            # по умолчанию и прогнал тесты по чужой базе, отчитавшись успехом.
            if ([string]$functionalInfoBase.Kind -eq "server") {
                throw (
                    "The functional stand resolved to a server infobase ($($functionalInfoBase.Display)), but " +
                    "functionalTests.smokeScript takes a file path only. Point -Database at a file stand, or extend " +
                    "the adapter to accept server coordinates before using -FunctionalTest with it."
                )
            }

            $functionalResultPath = Join-Path $stateDirectory "reports\probe-functional-$timestamp.txt"
            if ($useUnitTests) {
                # Движок модульных тестов сам отбирает по именам и сам пишет отчёт
                # машиночитаемым форматом, поэтому своей сверки отбора здесь не
                # нужно — её делает адаптер.
                $probeArguments = @(
                    "-BasePath", ([string]$functionalInfoBase.Path),
                    "-Tests", (@($probePlan.FunctionalTests) -join ","),
                    "-ReportPath", ($functionalResultPath -replace '\.txt$', '.xml')
                )
            }
            else {
                $probeArguments = @(
                    "-BasePath", ([string]$functionalInfoBase.Path),
                    "-Tests", (@($probePlan.FunctionalTests) -join ","),
                    "-ResultPath", $functionalResultPath,
                    # HTTP-проверки задаются адаптером списком и по имени не
                    # отбираются, а стенд под них Probe не публикует. Контракт
                    # HTTP проверяют обязательные фазы.
                    "-SkipHttp"
                )
            }
            try {
                Invoke-WorkflowPowerShell `
                    -ScriptPath (Resolve-WorkflowPath -RepositoryRoot $repositoryRoot -Path $probeRunnerRelative) `
                    -Arguments $probeArguments `
                    -LogPath (Join-Path $stateDirectory "logs\task-workflow\probe-functional-$timestamp.log") | Out-Null
            }
            catch {
                $probeFailure = [string]$_.Exception.Message
            }

            # Отбор обязан быть ПРИМЕНЁН, а не принят молча. Пустой список
            # результатов в этом формате читается как «OK»: адаптер, не понявший
            # ключ или не нашедший теста по имени, отчитается успехом, ничего не
            # выполнив. Сверяем названное с фактически выполненным.
            if ($null -eq $probeFailure -and -not $useUnitTests) {
                $selectionProblems = @(
                    Test-WorkflowFunctionalSmokeResult `
                        -ResultPath $functionalResultPath `
                        -ExpectedTests @($probePlan.FunctionalTests)
                )
                $unrequested = @(
                    Get-WorkflowUnrequestedFunctionalTests `
                        -ResultPath $functionalResultPath `
                        -ExpectedTests @($probePlan.FunctionalTests)
                )
                if ($unrequested.Count -gt 0) {
                    Write-Host "Адаптер выполнил сверх названного: $($unrequested -join ', ')."
                    Write-Host "  Если это не неделимая группа, отбор в адаптере накрывает не все тесты."
                }
                if ($selectionProblems.Count -gt 0) {
                    $probeFailure = (
                        "Отбор функциональных тестов не применён: $($selectionProblems -join '; '). " +
                        "Адаптер functionalTests.smokeScript обязан принимать -Tests и -ResultPath."
                    )
                }
            }
        }

        if ($probePlan.RunWebUi -and $null -eq $probeFailure) {
            if ($null -eq $webUiConfig -or -not [bool]$webUiConfig.enabled) {
                throw "Web UI scenarios were requested, but webUiTests.enabled is false."
            }
            $webUiInfoBase = Resolve-ProbeStand `
                -Kind "functional-ui" `
                -Description "Web UI stand" `
                -HowToBuild "$([string]$webUiConfig.script) (without -SkipStandInitialization)"
            $webUiStand = [string]$webUiInfoBase.Display
            Write-Host "Probe web ui stand: $webUiStand"
            # Функциональный контур грузит правки в СВОЮ базу, интерфейсный — в свою:
            # это разные стенды, и загрузка в один не делает актуальным другой.
            Invoke-ProbeApply -InfoBase $webUiInfoBase -Name "probe-apply-web-ui"

            $webUiReportPath = Join-Path $stateDirectory "reports\probe-web-ui-$timestamp.json"
            # Стенд передаётся тем же способом, каким он был выбран. Подставить путь
            # у серверного стенда нельзя: он пуст, и прогон свернулся бы к файловому
            # стенду по умолчанию — то есть к чужой базе, молча и «успешно».
            $webUiArguments = if ($Database) {
                @("-Database", $Database)
            }
            else {
                @("-BasePath", ([string]$webUiInfoBase.Path))
            }
            $webUiArguments += @(
                "-TestPath", (@($probePlan.WebUiTargets) -join ","),
                "-ReportPath", $webUiReportPath,
                # Стенд не пересобирается и данные не сдаются заново: правки уже
                # загружены выше, а сдача данных — это минуты, которых петля не стоит.
                "-SkipStandInitialization"
            )
            if ($Tags.Count -gt 0) {
                $webUiArguments += @("-Tags", ($Tags -join ","))
            }
            if ($Grep) {
                $webUiArguments += @("-Grep", $Grep)
            }
            if ($Bail) {
                $webUiArguments += "-Bail"
            }
            if ($V8Path) {
                $webUiArguments += @("-V8Path", $V8Path)
            }

            try {
                Invoke-WorkflowPowerShell `
                    -ScriptPath (Resolve-WorkflowPath -RepositoryRoot $repositoryRoot -Path ([string]$webUiConfig.script)) `
                    -Arguments $webUiArguments `
                    -LogPath (Join-Path $stateDirectory "logs\task-workflow\probe-$timestamp.log") | Out-Null
            }
            catch {
                $probeFailure = [string]$_.Exception.Message
            }
        }

        # Отчёт помечен probe. Пометка нужна не для отчётности: Verify ищет пригодный
        # для переиспользования отчёт Selfcheck, и отчёт петли обязан быть отвергнут
        # явно, а не только потому, что состояние не сдвинулось.
        $probeReport = [pscustomobject]@{
            schemaVersion = 1
            probe = $true
            reusable = $false
            phaseAdvanced = $false
            releaseReady = $false
            project = [string]$config.project
            branch = $branchName
            commit = $headCommit
            functionalStand = $functionalStand
            functionalTests = @($probePlan.FunctionalTests)
            functionalResult = $functionalResultPath
            webUiStand = $webUiStand
            webUiSelection = [string]$probePlan.WebUiSelection
            webUiTargets = @($probePlan.WebUiTargets)
            webUiReport = $webUiReportPath
            success = ($null -eq $probeFailure)
            failure = $probeFailure
            completedAt = [DateTimeOffset]::Now.ToString("o")
        }
        Write-WorkflowJson -Value $probeReport -Path $probeReportPath | Out-Null
        Write-Host "Probe report: $probeReportPath"
        Write-Host "Состояние задачи не изменено: Probe не заменяет ни одну обязательную фазу."
        if ($null -ne $probeFailure) {
            throw $probeFailure
        }
    }

    "Compile" {
        # verified в списке намеренно: после верификации почти всегда следуют правки
        # по замечаниям, и вернуться к компиляции обязано быть можно. Без этого
        # состояние после Verify было тупиковым — дефект обнаружился только тогда,
        # когда фазу впервые реально прогнали.
        #
        # Старые имена состояний тоже принимаются: у разработчика на диске может
        # лежать состояние, записанное до переименования, и отказ заставил бы его
        # пересоздавать базу без всякой на то причины.
        #
        # kit-updated тоже принимается: после подъёма комплекта разработчик
        # продолжает обычную работу в той же копии, и заставлять его начинать её
        # с пересоздания базы не за что.
        Assert-TaskState `
            -State $taskState `
            -AllowedPhases @(
                "ready", "compiled", "selfcheck-passed", "verified", "kit-updated",
                "checked", "preflight-passed", "review-ready"
            ) `
            -CurrentBranch $branchName

        # Gate идёт ПЕРВЫМ шагом фазы. Он не требует платформы 1С и занимает
        # секунды, но раньше жил только в Verify — то есть отсутствие BOM у .ps1,
        # CRLF в индексе и merge-коммит в задачной ветке всплывали после того, как
        # Compile и Selfcheck уже отработали. На замеренной итерации это 225 секунд
        # до отказа, известного на первой секунде.
        $gateReport = Join-Path $stateDirectory "reports\compile-gate-$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')-$PID.json"
        $gateArguments = @("-ReportPath", $gateReport)
        if ($branchName -eq [string]$config.mainBranch) {
            $gateArguments += "-SkipTestMaintenance"
        }
        else {
            $gateArguments += @("-BaseRef", "origin/$([string]$config.mainBranch)")
        }
        Invoke-WorkflowPhaseScript `
            -Name "ci-gate" `
            -ScriptName "..\ci\Invoke-Gate.ps1" `
            -Arguments $gateArguments | Out-Null

        $dryRunArguments = @("-DryRun")
        if ($BasePath) {
            $dryRunArguments += @("-BasePath", $BasePath)
        }
        if ($V8Path) {
            $dryRunArguments += @("-V8Path", $V8Path)
        }
        Invoke-WorkflowPhaseScript `
            -Name "apply-dry-run" `
            -ScriptName "Apply-GitChanges.ps1" `
            -Arguments $dryRunArguments | Out-Null

        $reportPath = Join-Path $stateDirectory "reports\compile-$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')-$PID.json"
        $preflightArguments = @("-CompileOnly", "-SkipFunctionalTests", "-ReportPath", $reportPath)
        if ($V8Path) {
            $preflightArguments += @("-V8Path", $V8Path)
        }
        Invoke-WorkflowPhaseScript `
            -Name "compile-preflight" `
            -ScriptName "Test-Configuration.ps1" `
            -Arguments $preflightArguments | Out-Null
        Save-TaskState `
            -NewPhase "compiled" `
            -Fingerprint (Get-WorkflowFingerprint -RepositoryRoot $repositoryRoot) `
            -ReportPath $reportPath | Out-Null
    }

    "KitUpdate" {
        # Подъём комплекта — не задача. Он не меняет ни одного исходника
        # конфигурации, и полный прогон над ней доказывал то, что уже доказано
        # на основной ветке: 111 секунд Selfcheck ради скриптов, которые в базу
        # не попадают. Фаза утверждает ровно то, что относится к делу:
        # правка состоит только из файлов комплекта, gate проходит новыми
        # правилами, и конфигурация с новым комплектом собирается.
        #
        # Чего она НЕ утверждает: что работает прикладная функциональность.
        # Поэтому состояние называется иначе, а не «verified»: облегчённый зачёт
        # обязан быть отличим от полного не по памяти разработчика, а по файлу.
        Assert-TaskState `
            -State $taskState `
            -AllowedPhases @(
                "ready", "compiled", "selfcheck-passed", "verified", "kit-updated",
                "checked", "preflight-passed", "review-ready"
            ) `
            -CurrentBranch $branchName

        $kitChange = Get-WorkflowKitOnlyChange `
            -RepositoryRoot $repositoryRoot `
            -BaseRef "origin/$([string]$config.mainBranch)"
        if (-not $kitChange.KitOnly) {
            if ($kitChange.Problem) {
                throw "KitUpdate неприменима: $($kitChange.Problem)"
            }
            # Смешанную ветку фаза не тянет молча до полного прогона: команда и
            # объём проверки обязаны совпадать, иначе «облегчённо» и «полностью»
            # становятся неразличимы по тому, что набрал разработчик.
            throw ("KitUpdate применима только к ветке, где изменены исключительно файлы комплекта. " +
                "Вне комплекта изменено: $(@($kitChange.Foreign) -join ', '). " +
                "Для такой ветки выполните Compile, Selfcheck и Verify.")
        }
        Write-Host "Правка ветки — только комплект процесса $($kitChange.ProcessVersion): файлов $(@($kitChange.Paths).Count)."

        $gateReport = Join-Path $stateDirectory "reports\kitupdate-gate-$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')-$PID.json"
        Invoke-WorkflowPhaseScript `
            -Name "ci-gate" `
            -ScriptName "..\ci\Invoke-Gate.ps1" `
            -Arguments @("-ReportPath", $gateReport, "-BaseRef", "origin/$([string]$config.mainBranch)") | Out-Null

        # Компиляция обязательна и здесь: правка комплекта меняет ИМЕННО то, чем
        # база собирается. Дефект в загрузке исходников иначе впервые обнаружился
        # бы у того, кто следующим возьмёт задачу, — а его правка к отказу
        # отношения не имеет, и искать он будет не там.
        $reportPath = Join-Path $stateDirectory "reports\kitupdate-$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')-$PID.json"
        $preflightArguments = @("-CompileOnly", "-SkipFunctionalTests", "-ReportPath", $reportPath)
        if ($V8Path) {
            $preflightArguments += @("-V8Path", $V8Path)
        }
        Invoke-WorkflowPhaseScript `
            -Name "kitupdate-preflight" `
            -ScriptName "Test-Configuration.ps1" `
            -Arguments $preflightArguments | Out-Null

        Save-TaskState `
            -NewPhase "kit-updated" `
            -Fingerprint (Get-WorkflowFingerprint -RepositoryRoot $repositoryRoot) `
            -ReportPath $reportPath | Out-Null
        Write-Host "Подъём комплекта зачтён. Прикладная функциональность этой фазой НЕ проверялась:"
        Write-Host "  выпуск из состояния 'kit-updated' не собирается, полное доказательство даёт первая обычная задача."
    }

    "Selfcheck" {
        Assert-TaskState `
            -State $taskState `
            -AllowedPhases @("compiled", "checked") `
            -CurrentBranch $branchName
        $currentFingerprint = Get-WorkflowFingerprint -RepositoryRoot $repositoryRoot
        if ([string]$taskState.fingerprint -ne $currentFingerprint) {
            throw "Files changed after Compile. Run Invoke-TaskWorkflow.ps1 -Phase Compile again."
        }
        if ($CompileOnly) {
            throw "Selfcheck must verify an applicable database configuration; -CompileOnly is not allowed."
        }

        $reportPath = Join-Path $stateDirectory "reports\selfcheck-$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')-$PID.json"
        $impact = Get-PlatformImpact -PhaseName "Selfcheck"
        if (-not $impact.Impacts) {
            Write-SkippedPreflightReport -Path $reportPath -Impact $impact
        }
        else {
            $preflightArguments = @(
                "-ReportPath", $reportPath,
                # CF на этой фазе не нужен никому: временное дерево удаляется в
                # конце, а выпуск делает preflight заново.
                "-SkipCfDump",
                "-WebUiScope", (Get-WorkflowWebUiScope -Config $config -PhaseKey "selfcheck" -Full:$Full)
            )
            if ($V8Path) {
                $preflightArguments += @("-V8Path", $V8Path)
            }
            if ($IncludeHttp) {
                $preflightArguments += "-IncludeHttp"
            }
            $runWebUiOnSelfcheck = Test-ConfigFlag -Object $config.webUiTests -Name "runOnFinish"
            if ($IncludeWebUi -or $runWebUiOnSelfcheck) {
                $preflightArguments += "-IncludeWebUi"
            }
            Invoke-WorkflowPhaseScript `
                -Name "selfcheck-preflight" `
                -ScriptName "Test-Configuration.ps1" `
                -Arguments $preflightArguments | Out-Null
        }

        # Ревью зовётся здесь, сразу после того как правка закончена и проверена
        # платформой. Отдельной командой его звали бы «когда-нибудь»: этап,
        # который надо вспомнить, выполняется реже всего. А менять решение дешевле
        # сразу после написания, чем перед самым MR.
        #
        # Отказ ревью оставляет фазу незачтённой намеренно: правка с открытым
        # блокирующим замечанием не «почти готова», она не готова.
        $reviewConfig = Get-WorkflowSettingValue -Object $config -Name "review" -Default $null
        $reviewEnabled = [bool](Get-WorkflowSettingValue -Object $reviewConfig -Name "enabled" -Default $false)
        $reviewAutoRun = [bool](Get-WorkflowSettingValue -Object $reviewConfig -Name "autoRun" -Default $true)
        if ($reviewEnabled -and $reviewAutoRun) {
            Invoke-WorkflowPhaseScript `
                -Name "selfcheck-critique" `
                -ScriptName "Invoke-CodeCritique.ps1" `
                -Arguments @() | Out-Null
        }

        Save-TaskState `
            -NewPhase "selfcheck-passed" `
            -Fingerprint (Get-WorkflowFingerprint -RepositoryRoot $repositoryRoot) `
            -ReportPath $reportPath | Out-Null
    }

    "Verify" {
        # Verify — верификация коммита, поэтому она допустима на свежей рабочей копии
        # рецензента, где локального состояния задачи нет. Но если состояние есть,
        # оно обязано подтверждать пройденный Selfcheck: иначе автор получил бы
        # верифицированный коммит, пропустив самопроверку.
        if ($null -ne $taskState -and [string]$taskState.branch -eq $branchName) {
            $allowedForVerify = @(
                "selfcheck-passed", "verified",
                "preflight-passed", "review-ready"
            )
            if (@($allowedForVerify) -notcontains [string]$taskState.phase) {
                if (-not $Force) {
                    throw "Phase '$($taskState.phase)' cannot transition to 'Verify' on branch '$branchName'. Run Selfcheck first, or pass -Force to verify a foreign commit deliberately."
                }
                Write-Warning "Verify is running with -Force from phase '$($taskState.phase)'; the local Selfcheck result does not back this commit."
            }
        }

        # Ветка, чей MR уже смержен, а сама она удалена сервером: пуш создаст её
        # заново и не откроет ничего. Проверка стоит ДО всей работы фазы, потому
        # что проверять коммит, которому некуда ехать, незачем.
        if (-not $Force -and (Test-WorkflowBranchGoneOnServer `
            -RepositoryRoot $repositoryRoot `
            -BranchName $branchName `
            -MainBranch ([string]$config.mainBranch))) {
            throw ("Ветка '$branchName' отслеживает origin/$branchName, которой на сервере нет: " +
                "её MR смержен, а ветку удалили. Пуш создаст ветку заново и не откроет ничего — " +
                "коммит останется в стороне от $([string]$config.mainBranch). Перенесите работу на " +
                "новую ветку: git checkout $([string]$config.mainBranch); git pull; " +
                "git checkout -b <новая>; git cherry-pick <коммит>. Осознанная проверка такой ветки — -Force.")
        }

        # Ревью проверяется ДО сборки: гонять базу и стенд ради правки, которую ревью
        # всё равно вернёт, — те самые лишние минуты, ради которых этап заводился.
        # Работу делает фаза Critique, здесь проверяется только её результат: фаза,
        # результат которой никто не спрашивает, — предложение, а не этап.
        Assert-WorkflowCritiqueResolved `
            -RepositoryRoot $repositoryRoot `
            -Config $config `
            -StateDirectory $stateDirectory `
            -Fingerprint (Get-WorkflowFingerprint -RepositoryRoot $repositoryRoot)

        # Маршрут правки. Ревью отвечает «правильно ли написано», а этот вопрос —
        # «нужно ли это делать и где этому место». После написания кода он стоит
        # переделки, поэтому у структурных правок замысел требуется записанным.
        if ($RouteDowngrade) {
            $downgradePath = Join-Path (Join-Path $stateDirectory "route") "downgrade.json"
            [System.IO.Directory]::CreateDirectory((Split-Path $downgradePath -Parent)) | Out-Null
            Set-Content -LiteralPath $downgradePath -Encoding UTF8 -Value (
                ConvertTo-Json -Depth 3 -InputObject ([pscustomobject]@{
                    branch = $branchName
                    reason = $RouteDowngrade
                    decidedAt = (Get-Date).ToString("o")
                }))
            Write-Host "Маршрут понижен: $RouteDowngrade"
        }

        $routeResult = Get-WorkflowChangeRoute `
            -Config $config `
            -ChangedPaths (Get-WorkflowChangedPaths -RepositoryRoot $repositoryRoot -BaseRef "origin/$([string]$config.mainBranch)") `
            -AddedPaths (Get-WorkflowAddedPaths -RepositoryRoot $repositoryRoot -BaseRef "origin/$([string]$config.mainBranch)")
        Assert-WorkflowRouteDecision `
            -RepositoryRoot $repositoryRoot `
            -Config $config `
            -StateDirectory $stateDirectory `
            -BranchName $branchName `
            -RouteResult $routeResult

        # Серверный gate выполняется здесь, а не только в CI. Его проверки платформу
        # 1С не требуют и идут секунды, а preflight из них дублирует ровно две:
        # source-integrity и test-maintenance. Остальные локально не выполняются
        # нигде, и среди них те, что ломают работу тише всего: отсутствие BOM у .ps1
        # (powershell-encoding) и merge-коммит в задачной ветке (rebase-only). Плюс
        # персональные файлы в отслеживаемых, CRLF в индексе, валидность
        # JSON-конфигурации и разбор всех скриптов.
        #
        # Gate идёт ДО preflight осознанно: он дешёвый, и падать на merge-коммите
        # или .ps1 без BOM разумнее до компиляции конфигурации.
        #
        # Локальный запуск не заменяет серверный: фазу можно не выполнить вовсе. Он
        # убирает только то, что проверки не выполняются НИГДЕ.
        $verifyStamp = "$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')-$PID"
        $gateReport = Join-Path $stateDirectory "reports\verify-gate-$verifyStamp.json"
        # Пути отчётов двух общих проверок задаются явно и передаются дальше в
        # preflight. Раньше gate и preflight выполняли source-integrity и
        # test-maintenance каждый по разу, на одних и тех же файлах, в одной фазе —
        # комментарий выше это признавал, но работа всё равно делалась дважды.
        $sharedIntegrityReport = Join-Path $stateDirectory "reports\verify-source-integrity-$verifyStamp.json"
        $sharedMaintenanceReport = Join-Path $stateDirectory "reports\verify-test-maintenance-$verifyStamp.json"
        $gateArguments = @(
            "-ReportPath", $gateReport,
            "-SourceIntegrityReportPath", $sharedIntegrityReport
        )
        if ($branchName -eq [string]$config.mainBranch) {
            # На основной ветке политике актуализации тестов не с чем сравнивать.
            $gateArguments += "-SkipTestMaintenance"
        }
        else {
            $gateArguments += @(
                "-BaseRef", "origin/$([string]$config.mainBranch)",
                "-TestMaintenanceReportPath", $sharedMaintenanceReport
            )
        }
        Invoke-WorkflowPhaseScript `
            -Name "ci-gate" `
            -ScriptName "..\ci\Invoke-Gate.ps1" `
            -Arguments $gateArguments | Out-Null

        $reportPath = Join-Path $stateDirectory "reports\verify-$verifyStamp.json"
        $verifyWebUiScope = Get-WorkflowWebUiScope -Config $config -PhaseKey "verify" -Full:$Full
        $verifyRequiresWebUi = [bool](
            (Test-ConfigFlag -Object $config.webUiTests -Name "enabled") -and (
                $IncludeWebUi -or (Test-ConfigFlag -Object $config.webUiTests -Name "requiredForReview")
            )
        )

        $impact = Get-PlatformImpact -PhaseName "Verify"
        $reuse = $null
        if ($impact.Impacts) {
            if ($Force) {
                # -Force означает «верифицируем чужой коммит намеренно». Отпечаток
                # его не подтверждает по определению, поэтому переиспользовать
                # нечего — и молча делать вид, что есть, нельзя.
                Write-Host "Verify выполняет проверку платформой заново: задан -Force."
            }
            else {
                $reuse = Get-ReusableSelfcheckReport `
                    -TaskState $taskState `
                    -RequiredWebUiScope $verifyWebUiScope `
                    -RequiresWebUi $verifyRequiresWebUi `
                    -RequiresHttp ([bool]$IncludeHttp)
            }
        }

        if (-not $impact.Impacts) {
            Write-SkippedPreflightReport -Path $reportPath -Impact $impact
        }
        elseif ($null -ne $reuse) {
            # Копия отчёта Selfcheck с явной пометкой происхождения. Отчёт Verify
            # обязан существовать и обязан говорить, что он производный: иначе
            # «проверено на этой фазе» стало бы неотличимо от «взято у предыдущей».
            Write-Host "Verify переиспользует результат Selfcheck: отпечаток совпадает, дерево чистое."
            Write-Host "  Отчёт Selfcheck: $($reuse.Path)"
            $derived = $reuse.Report
            Add-Member -InputObject $derived -NotePropertyName "reusedFromPhase" -NotePropertyValue "selfcheck" -Force
            Add-Member -InputObject $derived -NotePropertyName "reusedFromReport" -NotePropertyValue ([string]$reuse.Path) -Force
            Add-Member -InputObject $derived -NotePropertyName "reusedFingerprint" -NotePropertyValue ([string]$reuse.Fingerprint) -Force
            Add-Member -InputObject $derived -NotePropertyName "completedAt" -NotePropertyValue ([DateTimeOffset]::Now.ToString("o")) -Force
            Write-WorkflowJson -Value $derived -Path $reportPath | Out-Null
            Write-Host "Preflight report: $reportPath"
        }
        else {
            $preflightArguments = @(
                "-RequireClean",
                "-ReportPath", $reportPath,
                "-WebUiScope", $verifyWebUiScope,
                "-SourceIntegrityReport", $sharedIntegrityReport,
                "-TestMaintenanceReport", $sharedMaintenanceReport
            )
            if ($V8Path) {
                $preflightArguments += @("-V8Path", $V8Path)
            }
            if ($IncludeHttp) {
                $preflightArguments += "-IncludeHttp"
            }
            if ($IncludeWebUi) {
                $preflightArguments += "-IncludeWebUi"
            }
            Invoke-WorkflowPhaseScript `
                -Name "verify-preflight" `
                -ScriptName "Test-Configuration.ps1" `
                -Arguments $preflightArguments | Out-Null
        }
        Save-TaskState `
            -NewPhase "verified" `
            -Fingerprint (Get-WorkflowFingerprint -RepositoryRoot $repositoryRoot) `
            -ReportPath $reportPath | Out-Null
    }

    "Package" {
        # Сборка cf для проверки изменения, а не для выпуска.
        #
        # Разработчик сделал функциональность и хочет её потрогать. Полный регресс
        # ему для этого не нужен: он стоит большую часть времени прогона и
        # доказывает то, чего правка не касалась. Здесь проверяется только
        # затронутое, и на выходе — cf.
        #
        # Полный прогон остаётся у выпуска и запускается ОСОЗНАННО, своей фазой.
        # Разделение именно такое: перепутать сборку для проверки с выпуском
        # нельзя ни по имени файла, ни по признаку releaseReady в манифесте.
        #
        # Работает на задачной ветке — там, где идёт разработка.
        $packageArguments = @("-AffectedOnly", "-AllowNonMain")
        if ($V8Path) {
            $packageArguments += @("-V8Path", $V8Path)
        }
        if ($ReleaseOutputPath) {
            $packageArguments += @("-OutputPath", $ReleaseOutputPath)
        }
        if ($IncludeHttp) {
            $packageArguments += "-IncludeHttp"
        }
        if ($Force) {
            $packageArguments += "-Force"
        }
        Invoke-WorkflowPhaseScript `
            -Name "package" `
            -ScriptName "Build-Release.ps1" `
            -Arguments $packageArguments | Out-Null
        # Состояние задачи НЕ меняется: это сборка артефакта, а не шаг процесса.
        # Иначе следующий Selfcheck отказался бы работать из состояния "packaged",
        # и сборка cf мешала бы разработке вместо того, чтобы ей служить.
    }

    "Release" {
        if ($branchName -ne [string]$config.mainBranch) {
            throw "Release is allowed only from '$($config.mainBranch)'. Current branch: '$branchName'."
        }
        # Последним в этой копии был облегчённый подъём комплекта. Build-Release
        # сделает полный preflight сам, но отказ здесь нужен раньше и по другой
        # причине: состояние 'kit-updated' означает, что прикладную часть на новом
        # комплекте не проверял никто, а выпуск — это утверждение обратного.
        if ($null -ne $taskState -and [string]$taskState.phase -eq "kit-updated") {
            throw ("Последняя фаза в этой копии — KitUpdate: комплект поднят, прикладная функциональность не проверялась. " +
                "Выполните обычную задачу с Selfcheck и Verify, затем собирайте выпуск.")
        }
        $releaseArguments = @()
        if ($V8Path) {
            $releaseArguments += @("-V8Path", $V8Path)
        }
        if ($ReleaseOutputPath) {
            $releaseArguments += @("-OutputPath", $ReleaseOutputPath)
        }
        if ($IncludeHttp) {
            $releaseArguments += "-IncludeHttp"
        }
        if ($Stage) {
            $releaseArguments += "-Stage"
        }
        if ($AffectedOnly) {
            $releaseArguments += "-AffectedOnly"
        }
        if ($Force) {
            $releaseArguments += "-Force"
        }
        Invoke-WorkflowPhaseScript `
            -Name "release" `
            -ScriptName "Build-Release.ps1" `
            -Arguments $releaseArguments | Out-Null
        Save-TaskState `
            -NewPhase "released" `
            -Fingerprint (Get-WorkflowFingerprint -RepositoryRoot $repositoryRoot) | Out-Null
    }
}
