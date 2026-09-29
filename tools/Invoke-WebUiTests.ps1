[CmdletBinding()]
param(
    [string]$BasePath = "",

    # Имя или псевдоним стенда из .v8-project.json. Нужен, когда стенд живёт в
    # кластере, а не файлом под testBaseRoot.
    [string]$Database = "",
    [string]$V8Path = "",
    [int]$Port = 0,
    [string]$AppName = "",
    [ValidateRange(60, 3600)]
    [int]$CommandTimeoutSeconds = 0,
    [ValidateRange(300, 14400)]
    [int]$GlobalTimeoutSeconds = 0,
    [string]$ReportPath = "",
    [string]$ArtifactsPath = "",
    [string[]]$TestPath = @(),
    [string[]]$Tags = @(),
    [string]$Grep = "",
    [switch]$Bail,
    [switch]$RebuildStand,
    [switch]$SkipStandInitialization,
    [switch]$KeepApache,

    # Подключиться к уже опубликованному стенду вместо остановки и повторной
    # публикации. Нужен фазе, которая гоняет Web UI дважды: сначала затронутое
    # правкой, потом обязательный минимум.
    [switch]$ReuseApache
)

$ErrorActionPreference = "Stop"
$repositoryRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repositoryRoot "scripts\workflow\Workflow.Common.ps1")

$config = Get-WorkflowConfig -RepositoryRoot $repositoryRoot
if (-not [bool]$config.webUiTests.enabled) {
    throw "Web UI tests are disabled in .1c-workflow.json."
}

function Get-WebUiRoleTestPublications {
    param([Parameter(Mandatory = $true)][object]$Config)

    $property = $Config.webUiTests.PSObject.Properties["roleTestPublications"]
    if ($null -eq $property) {
        return @()
    }

    $result = @()
    $names = @{}
    $variables = @{}
    foreach ($entry in @($property.Value)) {
        $name = ([string]$entry.name).Trim()
        $userName = ([string]$entry.userName).Trim()
        $urlVariable = ([string]$entry.urlEnvironmentVariable).Trim()
        $passwordProperty = $entry.PSObject.Properties["passwordEnvironmentVariable"]
        $passwordVariable = if ($null -ne $passwordProperty) {
            ([string]$passwordProperty.Value).Trim()
        }
        else {
            ""
        }
        if ($name -notmatch '^[a-z0-9][a-z0-9-]{0,31}$') {
            throw "webUiTests.roleTestPublications.name must match ^[a-z0-9][a-z0-9-]{0,31}`$: '$name'."
        }
        if (-not $userName) {
            throw "webUiTests.roleTestPublications[$name].userName is required."
        }
        if ($urlVariable -notmatch '^[A-Z_][A-Z0-9_]*$') {
            throw "webUiTests.roleTestPublications[$name].urlEnvironmentVariable is invalid: '$urlVariable'."
        }
        if ($passwordVariable -and $passwordVariable -notmatch '^[A-Z_][A-Z0-9_]*$') {
            throw "webUiTests.roleTestPublications[$name].passwordEnvironmentVariable is invalid: '$passwordVariable'."
        }
        if ($names.ContainsKey($name)) {
            throw "Duplicate webUiTests.roleTestPublications name: '$name'."
        }
        if ($variables.ContainsKey($urlVariable)) {
            throw "Duplicate webUiTests.roleTestPublications urlEnvironmentVariable: '$urlVariable'."
        }
        $names[$name] = $true
        $variables[$urlVariable] = $true
        $password = ""
        if ($passwordVariable) {
            $password = [Environment]::GetEnvironmentVariable($passwordVariable, "Process")
            if ($null -eq $password) {
                throw "Environment variable $passwordVariable is required for Web UI role publication '$name'."
            }
        }
        $result += [pscustomobject]@{
            Name = $name
            UserName = $userName
            Password = [string]$password
            UrlEnvironmentVariable = $urlVariable
        }
    }
    return $result
}

$roleTestPublications = @(Get-WebUiRoleTestPublications -Config $config)
$ccRoot = Resolve-Cc1CSkillsRoot -Config $config
$v8Executable = Resolve-WorkflowV8Path -Config $config -V8Path $V8Path
$suitePath = Resolve-WorkflowPath `
    -RepositoryRoot $repositoryRoot `
    -Path ([string]$config.webUiTests.suite)
if (-not (Test-Path -LiteralPath (Join-Path $suitePath "webtest.config.mjs") -PathType Leaf)) {
    throw "Web UI regression suite was not found: $suitePath"
}
# Целей может быть несколько: обязательный объём складывается из smoke и
# затронутого отбором, а это разные каталоги сьюта. Раннер принимает несколько
# путей в одном прогоне, если они из одного сьюта, — поэтому стенд публикуется
# один раз, а не по разу на каждую цель.
#
# Список нормализуется здесь, потому что вызов через `powershell.exe -File` НЕ
# разбирает массивы: `-TestPath a,b` приходит одной строкой «a,b», а повторение
# `-TestPath a -TestPath b` PowerShell отклоняет как «specified more than once».
# Весь автомат вызывает скрипты именно через -File, поэтому любой массивный
# параметр в этих скриптах обязан сам разбирать перечисление через запятую.
$testTargets = @(
    foreach ($entry in @($TestPath)) {
        foreach ($item in ([string]$entry -split ',')) {
            $target = $item.Trim()
            if (-not $target) {
                continue
            }
            $candidate = Resolve-WorkflowPath -RepositoryRoot $repositoryRoot -Path $target
            if (-not (Test-WorkflowPathUnderRoot -Path $candidate -Root $suitePath)) {
                throw "Web UI test target must be inside the configured suite: $candidate"
            }
            if (-not (Test-Path -LiteralPath $candidate)) {
                throw "Web UI test target was not found: $candidate"
            }
            $candidate
        }
    }
)
if ($testTargets.Count -eq 0) {
    $testTargets = @($suitePath)
}

# Стенд Web UI выделяется на ветку: две параллельные задачи не должны делить одну
# файловую базу, один порт и одно имя приложения Apache. Правила выделения задаёт
# секция parallel в .1c-workflow.json.
$standBranch = Get-WorkflowStandBranchName -RepositoryRoot $repositoryRoot
if (-not $BasePath) {
    $BasePath = Get-WorkflowStandBasePath `
        -Config $config `
        -BranchName $standBranch `
        -Kind "functional-ui"
}
$standInfoBase = if ($Database) {
    Resolve-WorkflowInfoBase `
        -RepositoryRoot $repositoryRoot `
        -Config $config `
        -BranchName $standBranch `
        -Database $Database
}
else {
    ConvertTo-WorkflowInfoBase -BasePath $BasePath -Caller "Invoke-WebUiTests"
}
$isFileStand = [string]$standInfoBase.Kind -ne "server"
$baseFullPath = if ($isFileStand) { [System.IO.Path]::GetFullPath([string]$standInfoBase.Path) } else { "" }

# Сборка и сдача данных стенда идут проектным скриптом, а он знает только путь к
# файловой базе. Пока это так, серверный стенд допускается лишь готовым: молча
# свернуться к файловому пути нельзя — прогон ушёл бы на чужую базу и был бы
# зелёным, ничего не доказав.
if (-not $isFileStand -and -not $SkipStandInitialization) {
    throw (
        "A server-side Web UI stand cannot be built here: functionalTests.initializeScript takes a file path. " +
        "Prepare the stand once and re-run with -SkipStandInitialization."
    )
}
if ($Port -eq 0) {
    $Port = Get-WorkflowStandPort `
        -Config $config `
        -BranchName $standBranch `
        -Kind "web-ui" `
        -FallbackPort ([int]$config.webUiTests.defaultPort)
}
if (-not $AppName) {
    $AppName = Get-WorkflowStandAppName `
        -Config $config `
        -BranchName $standBranch `
        -DefaultAppName ([string]$config.webUiTests.defaultAppName)
}
if ($CommandTimeoutSeconds -eq 0) {
    $CommandTimeoutSeconds = [int]$config.webUiTests.commandTimeoutSeconds
}
if ($GlobalTimeoutSeconds -eq 0) {
    $GlobalTimeoutSeconds = [int]$config.webUiTests.globalTimeoutSeconds
}

$stateDirectory = Resolve-WorkflowPath `
    -RepositoryRoot $repositoryRoot `
    -Path ([string]$config.localStateDir)
$timestamp = "$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')-$PID"
$runDirectory = Join-Path $stateDirectory "web-ui\runs\$timestamp"
if (-not $ReportPath) {
    $ReportPath = Join-Path $runDirectory "results.json"
}
if (-not $ArtifactsPath) {
    $ArtifactsPath = Join-Path $runDirectory "artifacts"
}
$ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
$ArtifactsPath = [System.IO.Path]::GetFullPath($ArtifactsPath)
[System.IO.Directory]::CreateDirectory($runDirectory) | Out-Null
[System.IO.Directory]::CreateDirectory((Split-Path $ReportPath -Parent)) | Out-Null
[System.IO.Directory]::CreateDirectory($ArtifactsPath) | Out-Null

# Подготовка раннера общая с этапом сборки инструкций: копия пиннится по
# версии cc-1c-skills, зависимости и Chromium ставятся в локальном состоянии.
$webTestRuntime = Initialize-WorkflowWebTestRuntime `
    -Cc1CSkillsRoot $ccRoot `
    -StateDirectory $stateDirectory
$runtimeRoot = $webTestRuntime.Root
$previousBrowsersPath = $webTestRuntime.PreviousBrowsersPath
try {
    if ($isFileStand -and -not $SkipStandInitialization -and (
        $RebuildStand -or
        -not (Test-Path -LiteralPath (Join-Path $baseFullPath "1Cv8.1CD") -PathType Leaf)
    )) {
        $initialize = Resolve-WorkflowPath `
            -RepositoryRoot $repositoryRoot `
            -Path ([string]$config.functionalTests.initializeScript)
        $initializeArguments = @(
            "-BasePath", $baseFullPath,
            "-V8Path", $v8Executable,
            "-SkipRegistryUpdate"
        )
        if ($RebuildStand) {
            $initializeArguments += "-Recreate"
        }
        # Стенд собирается тем же порядком, что и в фазе, как только перед сидом
        # есть что ставить: расширения проекта или исполнитель кода стенда.
        # Инициализатор без -SkipSeed расширений не грузит, и стенд Web UI проекта
        # с расширениями рождался без них: тест доработки в расширении падал у
        # разработчика и проходил в фазе, а Probe догружал правки расширения в
        # базу, где самого расширения нет.
        $standExtensions = @(Get-WorkflowExtensions -RepositoryRoot $repositoryRoot -Config $config -AllowMissingOptional)
        if ($standExtensions.Count -gt 0 -or (Test-WorkflowStandExecEnabled -Config $config)) {
            Invoke-WorkflowStandPreparation `
                -RepositoryRoot $repositoryRoot `
                -Config $config `
                -BasePath $baseFullPath `
                -InitializeArguments $initializeArguments `
                -V8Path $v8Executable `
                -LogDirectory (Join-Path $stateDirectory "web-ui\logs")
        }
        else {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $initialize @initializeArguments
            if ($LASTEXITCODE -ne 0) {
                throw "Functional stand initialization failed with exit code $LASTEXITCODE."
            }
        }
    }

    # Наличие проверяется только у файлового стенда: про серверный отвечает кластер.
    if ($isFileStand -and -not (Test-Path -LiteralPath (Join-Path $baseFullPath "1Cv8.1CD") -PathType Leaf)) {
        throw "Web UI information base was not found: $baseFullPath"
    }

    $apachePath = Join-Path $stateDirectory "web-ui\apache"
    $stopScript = Resolve-CcSkillScript `
        -Cc1CSkillsRoot $ccRoot `
        -SkillName "web-stop" `
        -ScriptName "web-stop.ps1"

    # ── Переиспользование уже поднятого стенда ───────────────────────────────
    # Задачная фаза гоняет Web UI ДВАЖДЫ: сначала цели, доказывающие правку, потом
    # обязательный минимум, а между ними идёт функциональный дым. Останавливать и
    # публиковать Apache второй раз на том же порту нельзя: это ровно тот отказ,
    # ради которого ниже стоит Wait-WorkflowPortFullyFree — сокет остановленного
    # httpd догорает в TIME_WAIT, и навык публикации считает порт занятым. Пока
    # прогон был один, случай оставался редким; сделав его обязательным путём,
    # мы бы завели известную нестабильность в каждую фазу.
    #
    # Переиспользование ПРОВЕРЯЕТСЯ, а не предполагается: иначе «стенд уже поднят»
    # стало бы утверждением, которое нечем опровергнуть, и прогон молча ушёл бы
    # на чужой порт или в никуда.
    $reusedPort = 0
    if ($ReuseApache) {
        $savedPort = Get-WorkflowSavedStandPort `
            -RepositoryRoot $repositoryRoot `
            -Config $config `
            -Kind "web-ui" `
            -BranchName $standBranch
        $apacheInstalled = Test-Path -LiteralPath (Join-Path $apachePath "bin\httpd.exe") -PathType Leaf
        $rolePublicationsReady = $true
        foreach ($rolePublication in $roleTestPublications) {
            $roleVrd = Join-Path $apachePath "publish\$AppName-$($rolePublication.Name)\default.vrd"
            if (-not (Test-Path -LiteralPath $roleVrd -PathType Leaf)) {
                $rolePublicationsReady = $false
                break
            }
        }
        if ($savedPort -ne 0 -and $apacheInstalled -and $rolePublicationsReady -and
            (Test-WorkflowPortBusy -Port $savedPort)) {
            $reusedPort = $savedPort
            Write-Host "Web UI: переиспользуется опубликованный стенд на порту $reusedPort."
        }
        else {
            Write-Warning "Переиспользовать стенд Web UI не удалось (сохранённый порт: $savedPort) — публикуем заново."
        }
    }

    if ($reusedPort -eq 0 -and (Test-Path -LiteralPath (Join-Path $apachePath "bin\httpd.exe") -PathType Leaf)) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $stopScript -ApachePath $apachePath
        if ($LASTEXITCODE -ne 0) {
            throw "Stopping the isolated Web UI Apache failed with exit code $LASTEXITCODE."
        }
        # Остановка процесса не означает, что порт уже свободен: между завершением
        # httpd и освобождением сокета операционной системой есть зазор. Публикация
        # сразу после остановки периодически падала с «web-publish failed», причём
        # блокировка от конкурентов тут не помогает — конфликт со СВОИМ предыдущим
        # состоянием, а не с чужим.
        #
        # Это быстрый путь: если наш Apache только что остановлен, подождать здесь
        # дешевле. Решающее ожидание всё равно стоит перед публикацией — оно
        # выполняется и тогда, когда наш Apache остановила ПРЕДЫДУЩАЯ фаза, и этот
        # блок не срабатывает вовсе. Именно так дефект и всплыл.
        # Путь нашего httpd передаётся, чтобы отличить «наш сокет догорает» от
        # «порт держит чужой процесс». В первом случае ждать нужно, во втором —
        # бессмысленно: чужой слушатель порт не отдаст, а полминуты уходит на
        # каждом прогоне Web UI.
        $ownHttpd = Join-Path $apachePath "bin\httpd.exe"
        if (-not (Wait-WorkflowPortFullyFree -Port $Port -TimeoutSeconds 5 -OwnExecutablePath $ownHttpd)) {
            Write-Warning "Порт $Port не освободился; публикация подберёт другой порт из диапазона."
        }
    }

    $publish = Resolve-WorkflowPath `
        -RepositoryRoot $repositoryRoot `
        -Path ([string]$config.webUiTests.publishScript)
    $portRange = Get-WorkflowStandPortRange `
        -Config $config `
        -BranchName $standBranch `
        -Kind "web-ui"
    # Признак «Apache поднят и остановить его — наша обязанность». Отдельный от
    # $reusedPort: остановить в конце нужно и переиспользованный стенд, иначе
    # последний прогон фазы оставлял бы его висеть.
    $apacheRunning = $false
    $actualPort = 0
    try {
        # Переиспользуемый стенд уже опубликован и порт уже сохранён: подбор и
        # публикация пропускаются целиком, всё остальное идёт как обычно.
        $actualPort = $reusedPort
        if ($actualPort -eq 0) {
            # Подбор порта и публикация выполняются под межпроцессной блокировкой:
            # без неё два worktree выбирают один и тот же «свободный» порт между
            # проверкой и публикацией. Блокировка снимается сразу после публикации —
            # прогон тестов не сериализуется, порт уже занят поднятым Apache.
            $actualPort = Invoke-WithWorkflowLock -Config $config -Name "stand-publish" -Action {
                $candidate = Get-WorkflowFreePort `
                    -Config $config `
                    -StartPort $Port `
                    -MaxPort ([Math]::Max($portRange.End, $Port))
                if ($candidate -ne $Port) {
                    Write-Warning "Port $Port is busy; Web UI tests will use port $candidate."
                }
                # Навык публикации отказывается работать, если на порту есть ЛЮБОЕ
                # соединение, включая догорающий TIME_WAIT от предыдущего Apache — он
                # показывается как занятый процессом Idle с PID 0. Наш подбор считает
                # такой порт свободным намеренно (см. Test-WorkflowPortBusy), поэтому
                # согласование делаем здесь: ждём полного освобождения выбранного порта.
                #
                # Ожидание внутри блокировки: отпускать её и ждать снаружи нельзя, иначе
                # другая ветка займёт освободившийся порт между ожиданием и публикацией.
                while (-not (Wait-WorkflowPortFullyFree -Port $candidate -TimeoutSeconds 5)) {
                    $nextPort = $candidate + 1
                    if ($nextPort -gt $portRange.End) {
                        throw "No fully free Web UI port in range $($portRange.Start)-$($portRange.End). Last checked: $candidate."
                    }
                    Write-Warning "Port $candidate is not fully free; trying the next port in the branch range."
                    $candidate = Get-WorkflowFreePort `
                        -Config $config `
                        -StartPort $nextPort `
                        -MaxPort $portRange.End
                }
                # Вывод дочернего процесса ОБЯЗАТЕЛЬНО перехватываем: иначе он попадает
                # в поток успеха этого scriptblock, и блокировка возвращает массив
                # вместо номера порта, а собранный из него URL оказывается битым.
                # ErrorActionPreference при этом переводим в Continue: при Stop первая
                # же строка stderr дочернего процесса стала бы терминирующей ошибкой.
                $previousPublishErrorAction = $ErrorActionPreference
                $ErrorActionPreference = "Continue"
                $publishArguments = if ($Database) {
                    @("-Database", $Database)
                }
                else {
                    @("-BasePath", $baseFullPath)
                }
                $publishOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $publish `
                    @publishArguments `
                    -V8Path $v8Executable `
                    -ApachePath $apachePath `
                    -AppName $AppName `
                    -Port $candidate `
                    -SkipLock 2>&1
                $publishExitCode = $LASTEXITCODE
                $ErrorActionPreference = $previousPublishErrorAction
                $publishOutput | ForEach-Object { Write-Host ([string]$_) }
                if ($publishExitCode -ne 0) {
                    throw "Functional stand publication failed with exit code $publishExitCode."
                }

                foreach ($rolePublication in $roleTestPublications) {
                    $roleAppName = "$AppName-$($rolePublication.Name)"
                    $roleArguments = @($publishArguments) + @(
                        "-V8Path", $v8Executable,
                        "-ApachePath", $apachePath,
                        "-AppName", $roleAppName,
                        "-Port", $candidate,
                        "-UserName", $rolePublication.UserName,
                        "-SkipLock"
                    )
                    if ($rolePublication.Password) {
                        $roleArguments += @("-Password", $rolePublication.Password)
                    }
                    $ErrorActionPreference = "Continue"
                    $roleOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $publish `
                        @roleArguments 2>&1
                    $roleExitCode = $LASTEXITCODE
                    $ErrorActionPreference = $previousPublishErrorAction
                    $roleOutput | ForEach-Object { Write-Host ([string]$_) }
                    if ($roleExitCode -ne 0) {
                        throw "Web UI role publication '$($rolePublication.Name)' failed with exit code $roleExitCode."
                    }
                }
                return $candidate
            }
            Save-WorkflowStandPort `
                -RepositoryRoot $repositoryRoot `
                -Config $config `
                -Kind "web-ui" `
                -BranchName $standBranch `
                -Port $actualPort
        }
        $apacheRunning = $true

        # Базовая подготовка стенда (standBaseline): предопределённые данные,
        # первые диалоги, регламентные задания. После публикации — она идёт через
        # HTTP-исполнитель; переиспользованный стенд её уже прошёл.
        if ($reusedPort -eq 0) {
            $baselineLines = @(Invoke-WorkflowStandBaseline `
                -RepositoryRoot $repositoryRoot `
                -Config $config `
                -Url "http://localhost:$actualPort/$AppName" `
                -LogPath (Join-Path $runDirectory "stand-baseline.log"))
            foreach ($line in $baselineLines) {
                Write-Host "Стенд: $line"
            }
        }

        $urlEnvironmentVariable = if ([string]$config.webUiTests.urlEnvironmentVariable) {
            [string]$config.webUiTests.urlEnvironmentVariable
        }
        else {
            "ONEC_WEB_UI_URL"
        }
        $timeoutEnvironmentVariable = if ([string]$config.webUiTests.timeoutEnvironmentVariable) {
            [string]$config.webUiTests.timeoutEnvironmentVariable
        }
        else {
            "ONEC_UI_COMMAND_TIMEOUT_MS"
        }
        $previousUrl = [Environment]::GetEnvironmentVariable($urlEnvironmentVariable, "Process")
        $previousCommandTimeout = [Environment]::GetEnvironmentVariable($timeoutEnvironmentVariable, "Process")
        $previousRoleUrls = @{}
        try {
            $currentWebUiUrl = "http://localhost:$actualPort/$AppName"
            [Environment]::SetEnvironmentVariable(
                $urlEnvironmentVariable,
                $currentWebUiUrl,
                "Process"
            )
            [Environment]::SetEnvironmentVariable(
                $timeoutEnvironmentVariable,
                [string]($CommandTimeoutSeconds * 1000),
                "Process"
            )
            foreach ($rolePublication in $roleTestPublications) {
                $roleVariable = $rolePublication.UrlEnvironmentVariable
                $previousRoleUrls[$roleVariable] = [Environment]::GetEnvironmentVariable($roleVariable, "Process")
                $roleUrl = "http://localhost:$actualPort/$AppName-$($rolePublication.Name)"
                [Environment]::SetEnvironmentVariable($roleVariable, $roleUrl, "Process")
            }
            $runnerPath = Join-Path $runtimeRoot "run.mjs"
            $runnerArguments = @($runnerPath, "test") + $testTargets + @(
                "--report=$ReportPath",
                "--report-dir=$ArtifactsPath",
                "--global-timeout=$($GlobalTimeoutSeconds * 1000)"
            )
            if ($Bail) {
                $runnerArguments += "--bail"
            }
            if ($Tags.Count -gt 0) {
                $runnerArguments += "--tags=$($Tags -join ',')"
            }
            if ($Grep) {
                $runnerArguments += "--grep=$Grep"
            }

            $consoleLog = Join-Path $runDirectory "console.log"
            # ErrorActionPreference на время нативного вызова обязательно
            # переводим в Continue. В Windows PowerShell 5.1 перенаправление
            # stderr нативной команды через 2>&1 оборачивает КАЖДУЮ строку в
            # ErrorRecord, и при Stop первое же безобидное предупреждение runner'а
            # становится терминирующей ошибкой, обрывающей прогон на середине.
            # Так регрессия падала с state=partial при нуле упавших тестов.
            $previousErrorAction = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            try {
                $runnerOutput = @(& node.exe @runnerArguments 2>&1)
                $exitCode = $LASTEXITCODE
            }
            finally {
                $ErrorActionPreference = $previousErrorAction
            }
            [System.IO.File]::WriteAllLines(
                $consoleLog,
                @($runnerOutput | ForEach-Object { [string]$_ }),
                [System.Text.UTF8Encoding]::new($false)
            )
            $runnerOutput | ForEach-Object { Write-Host ([string]$_) }
            if ($exitCode -ne 0) {
                # Ранний отказ веб-клиента скрывает настоящую ошибку платформы за
                # общим сообщением «вход невозможен». Пока Apache ещё поднят,
                # повторно открываем тот же URL и раскрываем ТОЛЬКО безопасную
                # ссылку «Показать подробности». Кнопки перезапуска и завершения
                # сеансов пробник не нажимает.
                $runStartupDiagnostic = $false
                if (Test-Path -LiteralPath $ReportPath -PathType Leaf) {
                    try {
                        $runnerReport = Get-Content -LiteralPath $ReportPath -Raw -Encoding UTF8 | ConvertFrom-Json
                        $reportState = [string]$runnerReport.state
                        $reportTotal = if ($null -ne $runnerReport.summary) {
                            [int]$runnerReport.summary.total
                        }
                        else {
                            -1
                        }
                        $runStartupDiagnostic = ($reportState -eq "aborted" -and $reportTotal -eq 0)
                    }
                    catch {
                        Write-Warning "Web UI report could not be read for startup diagnostics: $($_.Exception.Message)"
                    }
                }
                if (-not $runStartupDiagnostic) {
                    $runnerText = @($runnerOutput | ForEach-Object { [string]$_ }) -join "`n"
                    $runStartupDiagnostic = [bool](
                        $runnerText -match 'cannot open context|startup blocked before the web client loaded'
                    )
                }

                $diagnosticSuffix = ""
                if ($runStartupDiagnostic) {
                    # Контекст с отдельной ролью может упасть раньше выполнения
                    # теста. Диагностировать нужно именно его URL, а не основной
                    # административный URL, иначе повторный вход будет зелёным и
                    # скроет реальный отказ прав или запуска клиента.
                    $diagnosticWebUiUrl = $currentWebUiUrl
                    $runnerText = @($runnerOutput | ForEach-Object { [string]$_ }) -join "`n"
                    $failedContextUrls = [regex]::Matches(
                        $runnerText,
                        '(?im)\bURL:\s*(https?://[^\s\)]+)'
                    )
                    if ($failedContextUrls.Count -gt 0) {
                        $diagnosticWebUiUrl = $failedContextUrls[$failedContextUrls.Count - 1].Groups[1].Value
                        Write-Host "Startup diagnostic target: failed Web UI context URL."
                    }
                    $diagnosticSource = Join-Path $PSScriptRoot "web-ui-startup-diagnostic.mjs"
                    $diagnosticRunner = Join-Path $runtimeRoot "workflow-startup-diagnostic.mjs"
                    $diagnosticJson = Join-Path $ArtifactsPath "startup-error-details.json"
                    if (Test-Path -LiteralPath $diagnosticSource -PathType Leaf) {
                        Copy-Item -LiteralPath $diagnosticSource -Destination $diagnosticRunner -Force
                        $diagnosticArguments = @(
                            $diagnosticRunner,
                            "--url=$diagnosticWebUiUrl",
                            "--artifact-dir=$ArtifactsPath",
                            "--timeout-ms=15000"
                        )
                        $previousDiagnosticErrorAction = $ErrorActionPreference
                        $ErrorActionPreference = "Continue"
                        try {
                            $diagnosticOutput = @(& node.exe @diagnosticArguments 2>&1)
                            $diagnosticExitCode = $LASTEXITCODE
                        }
                        finally {
                            $ErrorActionPreference = $previousDiagnosticErrorAction
                        }
                        $diagnosticLogLines = @("", "=== Workflow startup diagnostic ===") +
                            @($diagnosticOutput | ForEach-Object { [string]$_ })
                        [System.IO.File]::AppendAllText(
                            $consoleLog,
                            ($diagnosticLogLines -join [Environment]::NewLine) + [Environment]::NewLine,
                            [System.Text.UTF8Encoding]::new($false)
                        )
                        $diagnosticOutput | ForEach-Object { Write-Host ([string]$_) }

                        if (Test-Path -LiteralPath $diagnosticJson -PathType Leaf) {
                            try {
                                $diagnostic = Get-Content -LiteralPath $diagnosticJson -Raw -Encoding UTF8 | ConvertFrom-Json
                                $diagnosticSuffix = " Startup diagnostic: $([string]$diagnostic.state). Artifact: $diagnosticJson."
                                if ([string]$diagnostic.details) {
                                    $diagnosticDetails = ([string]$diagnostic.details -replace '\s+', ' ').Trim()
                                    if ($diagnosticDetails.Length -gt 500) {
                                        $diagnosticDetails = $diagnosticDetails.Substring(0, 500) + "..."
                                    }
                                    $diagnosticSuffix += " Details: $diagnosticDetails"
                                }
                            }
                            catch {
                                $diagnosticSuffix = " Startup diagnostic artifact could not be read: $diagnosticJson."
                            }
                        }
                        elseif ($diagnosticExitCode -ne 0) {
                            $diagnosticSuffix = " Startup diagnostic failed with exit code $diagnosticExitCode; original failure is preserved."
                        }
                    }
                    else {
                        $diagnosticSuffix = " Startup diagnostic adapter is missing: $diagnosticSource."
                    }
                }

                throw "Web UI regression failed with exit code $exitCode. Report: $ReportPath.$diagnosticSuffix"
            }
        }
        finally {
            [Environment]::SetEnvironmentVariable($urlEnvironmentVariable, $previousUrl, "Process")
            [Environment]::SetEnvironmentVariable(
                $timeoutEnvironmentVariable,
                $previousCommandTimeout,
                "Process"
            )
            foreach ($roleVariable in $previousRoleUrls.Keys) {
                [Environment]::SetEnvironmentVariable(
                    $roleVariable,
                    $previousRoleUrls[$roleVariable],
                    "Process"
                )
            }
        }
    }
    finally {
        if ($apacheRunning -and -not $KeepApache) {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $stopScript -ApachePath $apachePath
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Could not stop the isolated Web UI Apache."
            }
        }
    }
}
finally {
    $env:PLAYWRIGHT_BROWSERS_PATH = $previousBrowsersPath
}

Write-Host "Web UI report: $ReportPath"
Write-Host "Web UI artifacts: $ArtifactsPath"
